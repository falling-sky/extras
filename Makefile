DISTRIBUTE = falling-sky-chart.pl falling-sky-chart.sql falling-sky-chart.a29.pl
DIST_WORKDIR = work

all: mtu1280


dist-prep:
	rm -fr $(DIST_WORKDIR)
	mkdir -p $(DIST_WORKDIR)
	cp -p $(DISTRIBUTE) $(DIST_WORKDIR)

dist-test: dist-prep
	../dist_support/make-dist.pl --stage $(DIST_WORKDIR) --base extras --branch test

dist-stable: dist-prep
	../dist_support/make-dist.pl --stage $(DIST_WORKDIR) --base extras --branch stable

mtu1280:
	gcc mtu1280.c -lnetfilter_queue -o mtu1280
	sudo ./mtu1280  0
