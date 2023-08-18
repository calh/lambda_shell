FROM amazon/aws-cli

# Give us a full login sourced shell
SHELL ["/bin/bash", "-l", "-c"]
# Set the WORKDIR to root
WORKDIR /
# When deploying an ECR image to Lambda, the UID
# is always 993, user `sbx_user1051`.  The only
# part of the root filesystem that is writable is /tmp.
# Override all $HOME directories to /tmp to fool applications
# that want to use $HOME as a config or scratch space.
ENV HOME=/tmp

# Install some necessary tools we usually love to use
RUN yum install -y \
  bc \
  bind-utils \
  file \
  iputils \
  tar \
  traceroute \
  unzip 

# Other CLI apps that need to be pulled and installed manually
RUN curl -o /usr/local/bin/ecs-cli https://amazon-ecs-cli.s3.amazonaws.com/ecs-cli-linux-amd64-latest \
  && chmod 755 /usr/local/bin/ecs-cli \
  && curl -Lo /tmp/cw.tar.gz https://github.com/lucagrulla/cw/releases/download/v4.1.1/cw_4.1.1_Linux_x86_64.tar.gz \
  && mkdir -p /tmp/cw \
  && cd /tmp/cw \
  && tar xvf /tmp/cw.tar.gz \
  && mv cw /usr/local/bin \
  && chmod 755 /usr/local/bin/cw \
  && cd /tmp \
  && rm -Rf /tmp/cw \
  && curl -Lo /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 \
  && chmod 755 /usr/local/bin/jq

# If you changed the FROM image and need to install the AWS CLI, add this 
# to the RUN command above:
# && cd /tmp \
# && curl -Lo /tmp/aws.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
# && unzip /tmp/aws.zip \
# && bash /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin \
# && rm -f /tmp/aws.zip \


# Override the AWS CLI entrypoint command with our own 
# Lambda Runtime Interface Client
COPY entrypoint.sh /entrypoint.sh
COPY handler.sh /handler.sh
ENTRYPOINT ["/entrypoint.sh"] 

# Assume everyone will be using "handler.sh" as their code
# This can be overriden if you really want a different name.
CMD ["/handler.sh"]
