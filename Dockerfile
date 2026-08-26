FROM debian:12.14-slim

RUN apt-get update && \
    apt-get -y install \
        git \
        systemtap-sdt-dev \
        sysstat \
        bpfcc-tools \
        irqtop \
        bpftrace \
        linux-perf \
        libboost-all-dev \
        fish \
        curl \
        bc

RUN git clone https://github.com/brendangregg/FlameGraph.git /usr/local/bin
RUN git clone https://github.com/brendangregg/pmc-cloud-tools.git /tmp/utils && chmod +x /tmp/utils/* && mv /tmp/utils/* /usr/local/bin/


RUN curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash -s -- --system

COPY scripts/*.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/*.sh


CMD ["/bin/fish"]
