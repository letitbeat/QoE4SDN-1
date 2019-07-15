#!/bin/bash

# Used to collect statistics (min,max,avg and packet loss) of 
# packets traversing data plane paths in SDN architectures.

CONTROLLER_IP="${CONTROLLER_IP:-localhost}"
ONOS_USER="${ONOS_USER:-onos}"
ONOS_PASS="${ONOS_PASS:-rocks}"

DB_IP="${DB_IP:-172.17.0.4}"
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-qoe-db}"

# The amount of packets generated per second
GENERATION_RATE=5
# The total packets to be generated at each iteration
GENERATION_COUNT=10
# Total number of iterations
ITERATIONS=5

set_tz() {
  local container=$1
  docker exec $container cp /usr/share/zoneinfo/Europe/Paris /etc/localtime
}

install_nmap() {
  local container=$1
  set_tz $container
  docker exec -it $container bash -c "apt-get install nmap -y"
  touch nmap_installed
}

generate() {
    local rate=$1
    local count=$2
	docker exec -i mn.h1 nping -H -q1 --rate $rate -c $count --tcp -p 90 10.0.0.3
}

install_intent() {
  echo $(date) "Intent requested"
	curl -X POST -L -D resp.txt --user $ONOS_USER:$ONOS_PASS  \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json' -d '{ 
    "type": "HostToHostIntent", 
    "appId": "org.onosproject.gui", 
    "one": "'"$1"'/None",
    "two": "'"$2"'/None",
    "selector": {
      "criteria": [
        { 
          "type": "TCP_DST",
          "tcpPort": 90 
        }, 
        {
        "type": "IP_PROTO", 
        "protocol": 6
      }, 
        {
          "type" : "ETH_TYPE", 
          "ethType" : "0x0800" 
        }
  ]}
  }' http://"$CONTROLLER_IP":8181/onos/v1/intents &
}

delete_intent() {
  local location=$(grep -i Location resp.txt | awk '{print $2}')
  location=${location%$'\r'}
  curl -X DELETE -G --user $ONOS_USER:$ONOS_PASS "${location}"
  rm resp.txt
}

insert_metric() {
  local type=$1
  local value=$2
  query="insert into measure(datetime, \"parameter\", value) values(now(), '${type}', ${value});"
  docker run --rm -e PGPASSWORD=${DB_PASS} postgres psql -h ${DB_IP} -U ${DB_USER} -d qoe-db -c "${query}"
}

main() {

    # Check if required tools are installed in host
    if [ ! -f nmap_installed ]; then 
        install_nmap mn.h1
    fi

    i=0
    while [ $i -lt $ITERATIONS ]
    do 
        generate $GENERATION_RATE $GENERATION_COUNT > results_tmp.txt
        datetime=$(grep -i at results_tmp.txt | awk '{print $8,$9,$10}')

        max_rtt=$(grep -i "max rtt" results_tmp.txt | awk '{print $3}')
        min_rtt=$(grep -i "max rtt" results_tmp.txt | awk '{print $7}')
        avg_rtt=$(grep -i "max rtt" results_tmp.txt | awk '{print $11}')

        lost=$(grep -i "rcvd" results_tmp.txt | awk '{print $12}')
        packet_loss=$(echo "$lost / $GENERATION_COUNT" | bc -l)

        insert_metric "MAX_RTT" ${max_rtt//ms} >/dev/null
        insert_metric "MIN_RTT" ${min_rtt//ms} >/dev/null
        insert_metric "AVG_RTT" ${avg_rtt//ms} >/dev/null
        insert_metric "PACKET_LOSS" ${packet_loss} >/dev/null

        echo "$GENERATION_COUNT packets generated at " $(date)
        i=$[$i+1]
        sleep 5
    done

    rm results_tmp.txt
}
main
#cat results.txt

exit 0