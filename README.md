# AWS Lambda Shell 

This is a [Lambda Runtime Interface Client](https://docs.amazonaws.cn/en_us/lambda/latest/dg/runtimes-api.html) 
written in pure Bash and Curl.  It allows you to quickly create a simple bash script to run in Lambda 
for use cases like cron jobs or tasks that you want to quickly set up and deploy.

This also implements the [Lambda Function URL](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html) API to
to write HTTP endpoints in bash!

See [Examples](#Examples) below!

## Setting Up

* Install and configure [the AWS CLI client](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) on your workstation
* Install [jq](https://jqlang.github.io/jq/download/)
* Install [Docker](https://docs.docker.com/engine/install/)
* Copy this whole project directory to a new directory name for your project
  * Name the project root directory the same name as your intended Lambda function name
  * Edit this README.md and write documentation for your new thing
* Edit `script/environment` and change any configuration settings 
* Edit `script/create_function` and:
  * Review the `IAM_PERMISSIONS` array and make adjustments based on what you need to accomplish
  * The [policy wizard](https://us-east-1.console.aws.amazon.com/iam/home#/policies$new?step=edit) is pretty handy
  * Change the `SECURITY_GROUPS` to what is appropriate for the AWS account you're deploying this to
  * Change the `SUBNETS` to choose where you want this Lambda function to run
  * Review the `TAGS` array
  * Review `TIMEOUT` and `MEMORY`
* Review the `Dockerfile`
  * This uses the base image `amazon/aws-cli`, which is Amazon Linux 2, based off of RedHat 7
    * If you need something newer, `rockylinux:8` or `rockylinux:9` will also work
  * Add any RPM packages to the `yum install` command
  * Add any source package installs
  * `COPY` any extra bash files you write
* Edit `handler.sh` and write your code!  
  * You can use a different filename if you set the Dockerfile `CMD` to your new script name
  * Read below for SDK info
* Run:
```
$ ./script/create_function   # just one time
```
* If you want to update your function code and redeploy, do:
```
$ ./script/docker_build
$ ./script/docker_push
```
* If you screw up and want to start from scratch again:
```
$ ./script/delete_function
```

## Running and Testing

* Head to [Lambda Functions](https://us-east-1.console.aws.amazon.com/lambda/home?region=us-east-1#/functions) and 
  look at the `Test` tab for your function.  Create a new test rule, and paste in anything (or nothing) in the Event JSON
  and click the `Test` button
* Use the `cw` CLI tool to tail your log files from the log group `/aws/lambda/my_function_name`
* Create an EventBridge Rule to fire off your function at a cron interval
  * You can listen for other events like EC2 autoscaling, CloudWatch Alarms, GitHub push, AWS Health, RDS, S3 and many more
  * Information about the event is passed as a JSON object to the `$EVENT` variable

## Function URL

If you want to invoke your bash function via an HTTP client, first configure
a Function URL with the AWS CLI (or web console)

```
aws lambda create-function-url-config --function-name my_function_name --auth-type NONE
```

If you want your Function URL authenticated, [read more about that here](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html).

A simple example:

```
function handler()
{
  generate_http_response "Hello World!"
}
```

```
$ curl https://abcd1234.lambda-url.us-east-1.on.aws/
Hello World!
```

## Bash SDK

The `entrypoint.sh` script contains all of the logic for running your handler.  There are a few
environment variables and bash functions to make your life a little easier.

The function called `handler()` is executed each time a Lambda invocation is requested.  
You may source more bash scripts and call other functions.  Everything outside of the
`handler()` function is executed globally one time each time a new Lambda container 
is bootstrapped.  You don't have any control over how long containers last or how many
handlers are called for each container.

### Installed CLI Tools

* Bash version 4.2.46, Amazon Linux 2 distro
* Common Bash things like sed, awk, td, bc, tar, zip
* AWS CLI v2 (latest version)
* curl 7.79.1
* dig / nslookup
* ping, tracepath, traceroute, arping (and the IPv6 versions of these tools)
* ecs-cli (latest version)
* cw 4.1.1
* jq 1.6
* [Bash Mustache templates!](https://github.com/tests-always-included/mo)

### Bash Functions

`seconds_until_timeout()`

Returns the number of seconds until the Lambda timeout expires and your handler is given the axe.
This timeout is set in `script/create_function`, and you have a maximum of 15 minutes.

(Side note, if you're actually bumping into 15 minutes, you shouldn't use Lambda)

`ms_until_timeout()`

Same as above, except it returns the number of milliseconds until you're timed out

`ecs_ips_for_cluster("MyCluster", "MyService")`

Given an ECS cluster name and service name, return a newline delimited list of private
IP addresses for all of the running tasks

The `ecs-cli` tool offers this as well, but does not limit based on service name.

`parse_event()`

This uses jq to flatten the entire $EVENT object into environment
variables.  For example, this translates the Event JSON key
requestContext -> http -> userAgent to `$EVENT_REQUESTCONTEXT_HTTP_USERAGENT`

Any Array elements will have a suffix with the index, like
* `$EVENT_SERVERS_0="server1"`
* `$EVENT_SERVERS_1="server2"`

Read more about the [requestContext payload here](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html#http-api-develop-integrations-lambda.proxy-format).

If you call this explicitly, remember that this is setting global variables.
Call `unset_event()` at the end of your Lambda function so that they do 
not persist across subsequent invocations!

`unset_event()`

The reverse of above, clean up our global environment for the next lambda invocation.

`urldecode()`

URL hex decoder.

```
urldecode "my%20param=a+value" 
  => my param=a value
```

`urlencode()`

URL hex encoder

```
urlencode "my param=a value"
  => my%20param%3Da%20value
```

`parse_query_string()`

Declare global associative array HTTP_PARAMS.  Pass in an 
HTTP query string like "var1=my%20value&var2=val2" and 
it will URL decode values and populate array keys
* `HTTP_PARAMS[var1]="my value"`
* `HTTP_PARAMS[var2]="val2"`

This is a helper function of `parse_http_request()` below.

`parse_http_request()`

If this function was called as a Lambda Function URL,
parse the $EVENT -> requestContext -> http JSON and populate
Apache-style CGI environment variables:
* `REQUEST_METHOD`
* `QUERY_STRING`
* `SCRIPT_NAME`
* `CONTEXT_PATH`
* `REMOTE_ADDR`
* `SERVER_PROTOCOL`
* `HTTP_USER_AGENT`

Also creates the `HTTP_COOKIES` and `HTTP_PARAMS` associative array.

Example:

```
function handler()
{
  parse_http_request
  set
}
```

```
curl \
  -H 'Cookie: mycookie=cookievalue' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'post1=post%20value' \
  'https://abcd1234.lambda-url.us-east-1.on.aws/path/to/file?get=val1&get=val2'

HTTP_COOKIES=([mycookie]="cookievalue" )
HTTP_PARAMS=([get]="val2" [post1]="post value" )
EVENT_QUERYSTRINGPARAMETERS_GET=val1,val2
REQUEST_METHOD=POST
QUERY_STRING='get=val1&get=val2'
HTTP_USER_AGENT=curl/7.58.0
SCRIPT_NAME=/path/to/file
CONTEXT_PATH=/path/to
HTTP_HOST=abcd1234.lambda-url.us-east-1.on.aws
```

`join_by()`

Utility function.  Join an array by character, print string
Ex:  `join_by ',' "${cookies[@]}"`

`filename_extension()`

Utility function.  Print the extension of a given path and filename string.

`generate_http_response([OPTIONS] [Filename|String])`

OPTIONS:

* `--status INTEGER`:  Return this HTTP status code
* `--content-type STRING`:  Return this Content-Type response header
* `--cookie "key=value"`:  Return a cookie `key` and `value`.  Multiple `--cookie` parameters can be specified
* `--location URL`: Generate a 302 redirect.  Automatically sets `--status` code.

Filename Or String:

The only required parameter for `generate_http_response()` is a path to a filename, relative to root, or
a raw string.

If the string looks like a filename, and that file exists and is readable, `generate_http_response()`
will read the contents of the file, base64 encode it, and then set the `Content-Type` response header
to the MIME type of the file, if the `--content-type` parameter was not specified.

If the string is just plain text, `generate_http_response()` will also attempt to determine the 
MIME type using `file --mime` if the `--content-type` parameter was not specified.  The raw 
string is base64 encoded and supplied to the Lambda Function URL API as the HTTP response body.

See Examples below.

`generate_mustache_http_response()`

Same options as `generate_http_response()`, but instead, supply a Mustache template file 
as the Filename.  The Mustache template will be parsed into a temp file and passed to
`generate_http_response()`, and then the temp file is deleted.

Example:

index.json.mo
```
{ "SnapshotId": "{{SNAPSHOT_ID}}" }
```

```
function handler()
{
  SNAPSHOT_ID="snap-1234"
  # Content-Type: application/json will be set automatically
  generate_mustache_http_response "/index.json.mo"
}
```

### Environment Variables

`$_FUNCTION`

Default is `handler` -- if you want to use a different name for the handler function,
override this in the Dockerfile. 

IE:

```
ENV _FUNCTION=myhandler
```

`$REQUEST_ID`

The Lambda Request ID for this invocation

`$DEADLINE_EPOCH`

The epoch in seconds when the timeout will happen

`$FUNCTION_ARN`

The full ARN name of this Lambda function

`$TRACE_ID`

The Trace ID used in Lambda X-Ray.  (profiling your function)

`$EVENT`

The event payload, if you've given one to your function.  Event payloads can be 
set from EventBridge to give your function custom configuration settings.

NOTE:  The event payload is also passed as the first argument `$1` to your bash function.

Unless otherwise specified, most of the payloads will be JSON.

`$HOME`

The only writable location in the Lambda execution environment is `/tmp`.  
I'm setting `HOME=/tmp` for CLI tools like `ecs-cli` that seem to want to
store configuration data in `$HOME` and are too stupid to figure out any
fallback.

----

In addition to our custom variables above, AWS also offers a few interesting environment variables 
from the Lambda runtime.

`$AWS_ACCESS_KEY_ID`
`$AWS_DEFAULT_REGION`
`$AWS_SECRET_ACCESS_KEY`
`$AWS_SESSION_TOKEN`

The usual AWS CLI authentication variables are automatically filled in with ephemeral credentials 
that persist only for the lifetime of the running container.  Lambda uses the IAM Role given to
this function to create an access key.

`$AWS_LAMBDA_FUNCTION_MEMORY_SIZE`

The amount of memory in MB that was configured for this function

`$AWS_LAMBDA_FUNCTION_NAME`

The name of the Lambda function

`$AWS_LAMBDA_FUNCTION_VERSION`

The function version, like `$LATEST` 

`$AWS_LAMBDA_LOG_GROUP_NAME`

The CloudWatch log group name.  Example: `/aws/lambda/flexmaps_shapes_retention`

`$AWS_LAMBDA_LOG_STREAM_NAME`

The CloudWatch log stream name.  Example:  `2022/09/29/[$LATEST]5fff737ab02b4732a908e50a90847cea`

The hex code at the end can be used as a unique identifier for the running container

`$AWS_LAMBDA_RUNTIME_API`

Should be set to `127.0.0.1:9001`.  This is the HTTP endpoint to interact with the 
[Lambda runtime API](https://docs.amazonaws.cn/en_us/lambda/latest/dg/runtimes-api.html)

`$AWS_XRAY_DAEMON_ADDRESS`

Should be set to `169.254.79.129:2000`.  If you want to publish X-Ray data, 
[read about it here](https://docs.aws.amazon.com/xray/latest/devguide/xray-daemon.html)

`$HOSTNAME`

This is always set to a blank string.

`$UID`
`$USER`

This is always set to UID 993, username `sbx_user1051`

## Examples

### HTTP Router

Using the `$SCRIPT_NAME` variable, you can implement your own HTTP router with a case statement:

```
function handler()
{
  parse_http_request

  case "${SCRIPT_NAME}" in
    /)
      generate_http_response "index.html"
      ;;
    /status.json
      if [[ "${REQUEST_METHOD}" == "POST" ]]; then
        # update something
        STATUS="${HTTP_PARAMS[Status]}"
      fi
      generate_mustache_http_response "status.json.mo"
      ;;
    *)
      generate_http_response --status 404 "Not Found"
      ;;
  esac 
}
```

### HTTP Cookies

Generate HTTP response cookies, and validate request cookies

index.html.mo:
```
<html><body>
  Hi there {{HTTP_COOKIES.user}}!
</body></html>
```

```
function handler()
{
  parse_http_request

  if [[ "${HTTP_COOKIES[user]}" == "" ]]; then
    generate_http_response \
      --cookie "user=Bob" \
      --location "/"
  else
    generate_mustache_http_response "index.html.mo"
  fi
}
```

Note:  This example is horribly insecure.  Don't use something like this for authentication.
Sign and encrypt your cookies or use JSON Web Tokens.

### Proxy the AWS CLI

You can work with AWS's `--query` language, or just use `jq` to create the output you
desire.  You can specify `--content-type` header explicitly, or just rely on the 
`generate_http_response()` function's use of `file --mime` to autodetect the mime type.

For larger responses, you also might want to redirect output to a file 
and call `generate_http_response $tempfile` 

Don't forget to delete it after!

```
function handler()
{
  generate_http_response $(
    aws ec2 describe-network-interfaces \
      --query 'NetworkInterfaces[][{PrivateIpAddress:PrivateIpAddress,Description:Description}][]'
  )
}
```

```
curl https://abcd1234.lambda-url.us-east-1.on.aws
[
    {
        "PrivateIpAddress": "192.168.0.10",
        "Description": "arn:aws:ecs:us-east-1:1234:attachment/..."
    },
    {
        "PrivateIpAddress": "192.168.0.20",
        "Description": "Interface for NAT Gateway nat-1234"
    },
    . . . 
]
```

### Daily Billing Report

Pull EstimatedCharges from CloudWatch and forecast from Cost Explorer
then send an email via SES.

```
function handler()
{
  yesterday_bill=$(aws cloudwatch get-metric-statistics \
    --namespace "AWS/Billing" \
    --metric-name "EstimatedCharges" \
    --dimension "Name=Currency,Value=USD" \
    --start-time $(date +"%Y-%m-%dT%H:%M:00" --date="-24 hours") \
    --end-time $(date +"%Y-%m-%dT%H:%M:00") \
    --statistic Maximum \
    --period 60 \
    --output text | sort -r -k 3 | head -n 1 | cut -f 2
  )
  two_days_ago_bill=$(aws cloudwatch get-metric-statistics \
    --namespace "AWS/Billing" \
    --metric-name "EstimatedCharges" \
    --dimension "Name=Currency,Value=USD" \
    --start-time $(date +"%Y-%m-%dT%H:%M:00" --date="-48 hours") \
    --end-time $(date +"%Y-%m-%dT%H:%M:00" --date="-24 hours") \
    --statistic Maximum \
    --period 60 \
    --output text | sort -r -k 3 | head -n 1 | cut -f 2
  )

  delta_bill='$'"$(echo "$yesterday_bill $two_days_ago_bill" | awk '{print $1-$2}')"
  
  # Forecast for the end of month bill
  end_of_month=$(date --date="$(date +'%Y-%m-01') + 1 month - 1 second" "+%Y-%m-%d")
  next_month=$(date --date="$(date +'%Y-%m-01') + 1 month" "+%Y-%m-%d")
  forecast_json=$( aws ce get-cost-forecast \
    --time-period Start=$end_of_month,End=$next_month \
    --metric=AMORTIZED_COST \
    --granularity=MONTHLY
  )
  end_period=$( echo $forecast_json | jq -r '.ForecastResultsByTime[0].TimePeriod.End' )
  forecast_cost='$'"$(echo $forecast_json | jq -r '.ForecastResultsByTime[0].MeanValue' )"
 
  aws ses send-email \
    --from "me@example.com" \
    --destination "ToAddresses=me@example.com" \
    --message "Subject={Data=AWS Billing Report,Charset=utf8},Body={Html={Data=<pre>Last 24 hour bill `echo $bill`.<br><br>Bill forecast for period ending $end_period => $forecast_cost<br><br></pre>,Charset=utf8}}" 
}
```

### Automated Snapshots

Given a passed in EC2 instance ID from an EventBridge 
JSON config, snapshot this instance and add a Retention
tag for daily, weekly, monthly, quarterly and annually.

After the snapshot has finished, create an AMI with
the same tag.

```
function retention()
{
  local month=$(date +"%m")
  local day=$(date +"%d"`)
  local hour=$(date +"%H")
  local year=$(date +"%Y")
  local day_of_week=$(date +"%a")

  if [[ ("$month" == "01") && ("$day" == "01") ]]; then
    echo "annually"
  elif [[ ("$month" == "01" || "$month" == "04" || "$month" == "07" || "$month" == "10") && ("$day" == "01") ]]; then
    echo "quarterly"
  elif [[ ("$day" == "01") ]]; then
    echo "monthly"
  elif [[ ("$day_of_week" == "Sat" && $hour -ge 12) || ("$day_of_week" == "Sun" && $hour -lt 12) ]]; then
    echo "weekly"
  else
    echo "daily"
  fi
}

# Called with EventBridge event JSON {"InstanceID": "i-1234"}
function handler()
{
  parse_event
  instance_id="${EVENT_INSTANCEID}"

  # Grab the root volume ID
  volume_id=$(aws ec2 describe-volumes \
    --filters Name=attachment.instance-id,Values=$instance_id Name=attachment.device,Values=/dev/sda1 \
    --query 'Volumes[0].Attachments[0].VolumeId' --output text
  )

  # daily/weekly/monthly/quarterly/yearly
  retention_value=$(retention)

  # Start the snapshot process
  snapshot_id=$(aws ec2 create-snapshot \
    --volume-id $volume_id \
    --description "Automated $retention_value backup on $instance_id" 
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Retention,Value=$retention_value},{Key=InstanceID,Value=$instance_id}]" \
    --query 'SnapshotId' --output text
  )

  echo "Created Snapshot ID $snapshot_id"
 
  # clean up the $EVENT variables
  unset_event
}

```
