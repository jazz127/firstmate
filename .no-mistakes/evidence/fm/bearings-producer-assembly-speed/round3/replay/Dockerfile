FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server git jq perl procps && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /run/sshd && passwd -d root
ENV PATH=/opt/firstmate/bin:/usr/local/bin:/usr/bin:/bin
ENTRYPOINT ["/usr/sbin/sshd","-D","-e","-f","/lab/sshd_config"]
