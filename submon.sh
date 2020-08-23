#!/bin/bash

###############################################################################################################################################
#                       
#                        Magma AGW subscriber traffic monitor script.
#                        By  eduardoefb@gmail.com
#
###############################################################################################################################################

function delete_rules(){
   # Clear rules:
   iptables -S | grep ${CHAIN_PREFIX} | tac | while read l; do
      eval `echo ${l} | sed 's/\-N/\-X/g; s/\-A/\-D/g' | awk '{print "iptables "$0}'`
   done
}

function create_rules(){
   # Add rules based on subscribers:
   mobility_cli.py get_subscriber_table | grep -P 'IMSI\d{15}\s+\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+\w+\.\w+' | while read l; do
      imsi=`echo ${l} | awk '{print $1}'`
      ip=`echo ${l} | awk '{print $2}'`
      apn=`echo ${l} | awk '{print $3}'`      
      chain=${CHAIN_PREFIX}${imsi}
      iptables -N ${chain}"_DL" 2>/dev/null
      iptables -N ${chain}"_UL" 2>/dev/null
      iptables -A FORWARD -d ${ip} -j ${chain}"_DL"
      iptables -A FORWARD -s ${ip} -j ${chain}"_UL"
   done	
}

function collect_data(){
   # Get results
   date_str=`date +'%Y-%m-%d %H:%M:%S'`
   tmp_file=`mktemp`
   iptables -L -v -n -x | grep -oP '\d+\s+\d+\s+\w+IMSI\d+_(DL|UL)' | sed "s/${CHAIN_PREFIX}//g; s/_/ /g" | awk -v date="${date_str}" '{print date";"$2";"$3";"$4}' > ${tmp_file}
   
   # Check if file has data:
   if [ `cat ${tmp_file} | wc -l` -gt 0 ]; then
      meas_file=${HOSTNAME}_`date -d "${date_str}" +'%Y%m%d%H%M%S'`"_"`openssl rand -hex 3`".csv"
      sleep 2
      cat ${tmp_file} | while read l; do
         datetime=`echo $l | awk -F ';' '{print $1}'`
         bits=`echo $l | awk -F ';' '{print $2}'`      
         imsi=`echo $l | awk -F ';' '{print $3}'`
         dtype=`echo $l | awk -F ';' '{print $4}'`
         
         sql_command="INSERT INTO subtraffic (agw, imsi, date, bits, type) VALUES ('${hostname}', '${imsi}', '${datetime}', ${bits}, '${dtype}');"
         mysql --ssl-ca=/opt/submon/certs/ca.pem --ssl-cert=/opt/submon/certs/cert.pem --ssl-key=/opt/submon/certs/cert.key -h ${MYSQL_IP} -P ${MYSQL_PORT} -u ${MYSQL_USER} -p${MYSQL_PASSWD} -e "INSERT INTO ${MYSQL_TABLE} (agw, imsi, date, bits, type) VALUES ('${HOSTNAME}', '${imsi}', '${datetime}', ${bits}, '${dtype}');" ${MYSQL_DB} 2>/dev/null
         if [ $? -eq 0 ]; then
            logger "SQL COMMAND: ${sql_command} executed sucessfully!"            
         else
            logger "SQL COMMAND: ${sql_command} failed!"            
            echo ${l} >> ${PENDING_FILE}
         fi       
      done
      
      cat ${tmp_file} > ${MEAS_DIR}${meas_file}
      rm -f ${MEAS_DIR}/${meas_file}".gz" 2>/dev/null
      gzip ${MEAS_DIR}/${meas_file}    
   fi	
}

function collect_pending(){  
   cat ${PENDING_FILE} | while read l; do
      datetime=`echo $l | awk -F ';' '{print $1}'`
      bits=`echo $l | awk -F ';' '{print $2}'`      
      imsi=`echo $l | awk -F ';' '{print $3}'`
      dtype=`echo $l | awk -F ';' '{print $4}'`          
      sql_command="INSERT INTO subtraffic (agw, imsi, date, bits, type) VALUES ('${hostname}', '${imsi}', '${datetime}', ${bits}, '${dtype}');"
      mysql --ssl-ca=/opt/submon/certs/ca.pem --ssl-cert=/opt/submon/certs/cert.pem --ssl-key=/opt/submon/certs/cert.key -h ${MYSQL_IP} -P ${MYSQL_PORT} -u ${MYSQL_USER} -p${MYSQL_PASSWD} -e "INSERT INTO ${MYSQL_TABLE} (agw, imsi, date, bits, type) VALUES ('${HOSTNAME}', '${imsi}', '${datetime}', ${bits}, '${dtype}');" ${MYSQL_DB} 2>/dev/null
      if [ $? -eq 0 ]; then                                               
         logger "PENDING SQL COMMAND: ${sql_command} executed sucessfully!"
         sed -i "/${l}/d" ${PENDING_FILE}         
      else               
         logger "PENDING SQL COMMAND: ${sql_command} failed!"                                    
      fi
   done
}


mkdir -p ${MEAS_DIR} 2>/dev/null
touch ${PENDING_FILE}
while :; do      
   collect_data
   delete_rules
   create_rules
   collect_pending
   sleep ${INTERVAL}
done

