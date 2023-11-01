####################
# If you don't want a fresh SQLite build, 
# comment this section out, along with the
# COPY command below.
FROM amazon/aws-cli AS sqlite-build
RUN yum install -y \
  gcc \
  unzip
# Specify an SQLite version here
ENV SQLITE_VERSION 3440000
RUN curl -o /tmp/sqlite.zip https://www.sqlite.org/2023/sqlite-amalgamation-$SQLITE_VERSION.zip
RUN cd /tmp && unzip sqlite.zip
RUN cd /tmp/sqlite-amalgamation-$SQLITE_VERSION/ && gcc shell.c sqlite3.c -lpthread -ldl -lm -o /tmp/sqlite


####################
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

# Other CLI apps that need to be installed from tarballs manually
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

# If you don't want a newer SQLite, comment this out
COPY --from=sqlite-build /tmp/sqlite /usr/bin/sqlite

# The aws-cli Docker image defines its own ENTRYPOINT to use 
# the `aws` command.  Since we're repurposing this image, o
# override the entrypoint command with our own 
# Lambda Runtime Interface Client
COPY entrypoint.sh /entrypoint.sh
COPY handler.sh /handler.sh
ENTRYPOINT ["/entrypoint.sh"] 

# The Docker CMD command defines the handler exec hook for Lambda.
# This can be overriden if you really want a different name.
CMD ["/handler.sh"]
