#!/bin/bash

# If we're not running from Lambda, just exec the CMD args
if [[ -z ${_HANDLER+x} ]]; then
  exec $*
fi

# Wait for the next invocation event from Lambda
function getinvocation()
{
  # Maximum lambda execution time is 15 minutes
  response=$(curl --max-time 900 -si \
    -w "\n%{size_header},%{size_download}" \
    "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/next")

  # Extract the response header size.
  headerSize=$(sed -n '$ s/^\([0-9]*\),.*$/\1/ p' <<< "${response}")

  # Extract the response body size.
  bodySize=$(sed -n '$ s/^.*,\([0-9]*\)$/\1/ p' <<< "${response}")

  # Extract the response headers.
  headers="${response:0:${headerSize}}"

  # Extract the response body as the event payload
  EVENT="${response:${headerSize}:${bodySize}}"
}

# Report a runtime error from the function
function report_error()
{
  ERROR="{\"errorMessage\" : \"$1\", \"errorType\" : \"BashRuntimeError\"}"
  curl -s -H "Lambda-Runtime-Function-Error-Type: Unhandled" -d "$ERROR" \
    "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/$REQUEST_ID/error" > /dev/null 
}

# Report a more critical bootstrapping error
function report_init_error()
{
  ERROR="{\"errorMessage\" : \"Failed to source the bash script file ${_HANDLER}.\", \"errorType\" : \"BashSourceError\"}"
  curl -s -H "Lambda-Runtime-Function-Error-Type: Unhandled" -d "$ERROR" \
    "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/init/error" > /dev/null
}

# Utility function, number of seconds until Lambda gives you the axe
function seconds_until_timeout()
{
  delta=$( expr $DEADLINE_EPOCH - $(date '+%s') )
  echo $delta
}

# Same as above but in milliseconds
function ms_until_timeout()
{
  delta=$( expr $DEADLINE_MS - $(($(date '+%s%N')/1000000)) )
  echo $delta
}

# The `ecs-cli ps` command offers this, but it does not restrict
# for a specific service within a cluster.  This AWS CLI function
# wrapper takes arguments for cluster and service, and returns
# a newline delimited list of IP addresses running in that service.
function ecs_ips_for_cluster()
{
  cluster=$1
  service=$2
  aws ecs describe-tasks \
    --cluster $cluster \
    --tasks $( aws ecs list-tasks --cluster $cluster --service $service --output text --query 'taskArns' ) \
    --query "tasks[].attachments[?type=='ElasticNetworkInterface'][].details[?name=='privateIPv4Address'].[value]" \
    --output text
}

# This uses jq to flatten the entire $EVENT object into environment
# variables.  For example, this translates the Event JSON key
# requestContext -> http -> userAgent to
#   $EVENT_REQUESTCONTEXT_HTTP_USERAGENT
# Any Array elements will have a suffix with the index, like
#   $EVENT_SERVERS_0="server1"
#   $EVENT_SERVERS_1="server2"
function parse_event()
{
  eval $(
    echo "${EVENT}" \
      | jq -r '
        . as $in 
        | reduce leaf_paths as $path 
          (
            {}; . + 
              { 
                (
                  $path 
                  | map(tostring) 
                  | "EVENT_" + join("_") 
                  | gsub("\\W"; "_") 
                  | ascii_upcase): 
                    $in | getpath($path) 
              }
          ) | 
          to_entries 
          | map("\(.key)=\"\(.value|tostring)\"") 
          | .[]
      '
  )
}

# The reverse of above, clean up our global environment 
# for the next lambda run
function unset_event()
{
  eval $(
    echo "${EVENT}" \
      | jq -r '
        . as $in 
        | reduce leaf_paths as $path 
          (
            {}; . + 
              { 
                (
                  $path 
                  | map(tostring) 
                  | "EVENT_" + join("_") 
                  | gsub("\\W"; "_") 
                  | ascii_upcase): 
                    $in | getpath($path) 
              }
          ) | 
          to_entries 
          | map("unset \(.key)")
          | .[]
      '
  )
  unset EVENT
}

# URL hex decoder
function urldecode() 
{ 
  : "${*//+/ }"; echo -e "${_//%/\\x}"; 
}

# URL hex encoder
function urlencode() {

  local LC_COLLATE=C

  local length="${#1}"
  for (( i = 0; i < length; i++ )); do
    local c="${1:$i:1}"
    case $c in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# Declare global associative array HTTP_PARAMS.  Pass in an 
# HTTP query string like "var1=my%20value&var2=val2" and 
# it will URL decode values and populate array keys
# HTTP_PARAMS[var1]="my value"
# HTTP_PARAMS[var2]="val2"
function parse_query_string() 
{
  local IFS='=&'
  local param_array=($1)
  declare -gA HTTP_PARAMS
  for ((i=0; i<${#param_array[@]}; i+=2))
  do
    HTTP_PARAMS[${param_array[i]}]=$(urldecode "${param_array[i+1]}")
  done
}

# If this function was called as a Lambda Function URL,
# parse the $EVENT->requestContext->http JSON and populate
# Apache-style CGI environment variables:
# * REQUEST_METHOD
# * SCRIPT_NAME
# * CONTEXT_PATH
# * REMOTE_ADDR
# * SERVER_PROTOCOL
# * HTTP_USER_AGENT
# 
# Also creates the HTTP_COOKIES and HTTP_PARAMS associative array
function parse_http_request()
{
  parse_event

  REQUEST_METHOD="${EVENT_REQUESTCONTEXT_HTTP_METHOD}"
  SCRIPT_NAME="${EVENT_REQUESTCONTEXT_HTTP_PATH}"
  SERVER_PROTOCOL="${EVENT_REQUESTCONTEXT_HTTP_PROTOCOL}"
  REMOTE_ADDR="${EVENT_REQUESTCONTEXT_HTTP_SOURCEIP}"
  HTTP_USER_AGENT="${EVENT_REQUESTCONTEXT_HTTP_USERAGENT}"
  CONTEXT_PATH=$( dirname "${SCRIPT_NAME}" )
  HTTP_HOST="${EVENT_HEADERS_HOST}"
  # Host header and SERVER_NAME can be different in Apache terms,
  # however it seems that AWS Function URLs don't allow virtual hosting
  SERVER_NAME="${EVENT_REQUESTCONTEXT_DOMAINNAME}"
  QUERY_STRING="${EVENT_RAWQUERYSTRING}"

  # Go through EVENT_COOKIES_* and make create a nicer associative array
  unset HTTP_COOKIES
  declare -gA HTTP_COOKIES
  for ((i=0 ; 1 ; i++)); do
    local var="EVENT_COOKIES_${i}"
    if [[ "${!var}" == "" ]]; then
      break
    fi

    local key=$(echo "${!var}" | cut -d'=' -f1)
    local value=$(echo "${!var}" | cut -d'=' -f2-)
    HTTP_COOKIES["${key}"]="${value}"
  done

  unset HTTP_PARAMS
  # POST request body
  parse_query_string "$(echo "${EVENT_BODY}" | base64 --decode)"
  # GET parameters
  parse_query_string "${QUERY_STRING}"
}


# Join an array by character
# Ex:  join_by ',' "${cookies[@]}"
function join_by ()
{
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

function filename_extension()
{
  local filename=$(basename -- "$1")
  local extension="${filename##*.}"
  echo "${extension}"
}

function generate_http_response()
{
  local options=$(getopt --long status:,content-type:,cookie:,location: -- "" "$@")
  eval set -- "$options"

  local status="200"
  local content_type=""
  local cookies=()
  local location=""

  while true; do
    case "$1" in
      --status)
        status="$2"
        shift 2
        ;;
      --content-type)
        content_type="$2"
        shift 2
        ;;
      --cookie)
        cookies+=("\"$2\"")
        shift 2
        ;;
      --location)
        location="$2"
        shift 2
        ;;
      --)
        shift
        break;
        ;;
      *)
        echo "generate_http_response: Invalid option $1"
        break;
        ;;
    esac
  done

  local body=""
  # If the body is a filename
  if [[ -e "$1" ]]; then
    body="$(base64 --wrap=0 "$1")"
    # If the content_type hasn't been given
    if [[ "$content_type" == "" ]]; then
      content_type=$(file -bi "$1")
    fi
  else  # body is a string
    body="$(echo "$1" | base64 --wrap=0 )"
    # If the content_type hasn't been given,
    # try out best to use `file` to guess it
    if [[ "$content_type" == "" ]]; then
      content_type="$(echo "$1" | file -bi -)"
    fi
  fi

  if [[ "${location}" != "" && "${status}" == "200" ]]; then
    status="302"
  fi

  # After we generate a response, reset all of the global 
  # variables that we might have set
  unset HTTP_COOKIES
  unset HTTP_PARAMS
  unset REQUEST_METHOD
  unset SCRIPT_NAME
  unset SERVER_PROTOCOL
  unset REMOTE_ADDR
  unset HTTP_USER_AGENT
  unset CONTEXT_PATH
  unset HTTP_HOST
  unset SERVER_NAME
  unset QUERY_STRING
  unset_event

  RESPONSE_PAYLOAD="{
    \"statusCode\": $status,
    \"headers\": {
      \"Content-Type\": \"$content_type\",
      \"Location\": \"$location\"
    },
    \"body\": \"$body\",
    \"cookies\": [$(join_by ',' "${cookies[@]}")],
    \"isBase64Encoded\": true
  }"

}

# Wrapper for generate_http_response() with Mustache template
function generate_mustache_http_response()
{
  tmpfile=$(mktemp)
 
  if [[ $(type -t mo) != "function" ]]; then
    source "/usr/local/bin/mo"
  fi 

  # Save the template filename as the last arg
  # (with other optional header args)
  mo_file="${!#}"
  # Reset the whole arg array without the template filename
  set -- "${@:1:$(($#-1))}"

  mo "$mo_file" > $tmpfile
  
  generate_http_response $* "$tmpfile"
  
  rm -f "$tmpfile"
}

echo "Including handler ${_HANDLER}..."
source ${_HANDLER}
ret=$?
if [[ "$ret" != 0 ]]; then
  echo "Error trying to source the Lambda script: $ret"
  report_init_error 
fi

# _FUNCTION default name
if [[ "${_FUNCTION}" == "" ]]; then
  _FUNCTION=handler
fi

while [ 1 ]; do
  echo "Waiting for next Lambda invocation event..."
  getinvocation

  REQUEST_ID=$(echo "$headers" | grep Lambda-Runtime-Aws-Request-Id | awk '{print $2}' | tr -d '\r')
  DEADLINE_MS=$(echo "$headers" | grep Lambda-Runtime-Deadline-Ms | awk '{print $2}' | tr -d '\r')
  DEADLINE_EPOCH=$( expr $DEADLINE_MS / 1000 )
  FUNCTION_ARN=$(echo "$headers" | grep Lambda-Runtime-Invoked-Function-Arn | awk '{print $2}' | tr -d '\r')
  TRACE_ID=$(echo "$headers" | grep Lambda-Runtime-Trace-Id | awk '{print $2}' | tr -d '\r')
  #echo "headers: $headers"
  #echo "event: $EVENT"
  #echo "ID: '$REQUEST_ID'"

  if [[ -z "$REQUEST_ID" ]]; then
    echo "No request ID?  I guess we'll go back to waiting..."
    sleep 1
    continue
  fi

  RESPONSE_PAYLOAD="SUCCESS"

  echo "Executing handler... "

  $_FUNCTION "$EVENT"

  ret=$?
  if [[ "$ret" != 0 ]]; then
    echo "Error executing the Lambda function: $ret"
    report_error "Error executing the Lambda function: Exit $ret"
    continue
  fi

  curl -s -d "${RESPONSE_PAYLOAD}" "http://${AWS_LAMBDA_RUNTIME_API}/2018-06-01/runtime/invocation/$REQUEST_ID/response" > /dev/null

done
