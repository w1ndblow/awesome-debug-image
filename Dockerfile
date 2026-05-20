FROM debian:12.14-slim

RUN apt-get update && apt-get -y install git systemtap-sdt-dev sysstat bpfcc-tools irqtop bpftrace linux-perf libboost-all-dev fish

RUN git clone https://github.com/brendangregg/FlameGraph.git /usr/local/bin
RUN git clone https://github.com/brendangregg/pmc-cloud-tools.git /tmp/utils && chmod +x /tmp/utils/* && mv /tmp/utils/* /usr/local/bin/
CMD ["/bin/fish"]
