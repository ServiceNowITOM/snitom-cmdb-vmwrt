FROM iron/perl:dev
MAINTAINER Reuben Stump (reuben.stump@servicenow.com)

# Install cpanm
RUN apk update --no-cache --purge

# Install libraries
RUN apk add openssl-dev
RUN apk add libxml2-dev

# Install Perl modules
RUN cpanm install \
	Class::Autouse \
	Exception::Class \
	Net::SSLeay \
	XML::LibXML \
	LWP \
	LWP::ConnCache \
	LWP::Protocol::https \
	URI \
	JSON::XS \
	Path::Tiny \
	HTTP::Cookies \
	Log::Log4perl

RUN mkdir -p /opt/vmwrt/lib
RUN mkdir -p /opt/vmwrt/etc

WORKDIR /opt/vmwrt

# Install p5-vmomi
COPY ./p5-vmomi/lib/ /opt/vmwrt/lib/

# Install vmwrt
COPY ./snitom-cmdb-vmwrt/vmwrt.pl /opt/vmwrt/

ENTRYPOINT ["/usr/bin/perl"]
CMD ["vmwrt.pl"]
