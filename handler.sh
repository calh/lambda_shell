#!/bin/bash
# An example bash Lambda function

echo "I'm doing stuff during the container initialization here!"
echo "It will happen only once when a container is bootstrapped."

THIS_IS_SHARED_ACROSS_HANDLER_INVOCATIONS_ON_THIS_CONTAINER=$RANDOM

# The handler is executed by the entrypoint.sh script in a wait-loop
function handler()
{
  # Do something for each running container in an ECS cluster
  for IP in $( ecs_ips_for_cluster "MyCluster" "MyService" ); do
    echo $IP
    if [[ "$(seconds_until_timeout)" -le "2" ]]; then
      echo "Uh oh, I better wrap things up..."
      return 1
    fi
    ping -c 1 "${IP}"
    if [[ "$?" != "0" ]]; then
      echo "Couldn't ping $IP"
    fi
    curl --max-time 3 -s "${IP}"
    if [[ "$?" != "0" ]]; then
      echo "HTTP is dead on $IP"
    fi
  done
}
