DISTRIBUTE = falling-sky-chart.pl falling-sky-chart.sql falling-sky-chart.a29.pl falling-sky-dyngraphs-csv.pl  README.md
DIST_WORKDIR = work
DIST_STABLE ?= jfesler@rsync.gigo.com:/home/fsky/stable/extras


dist-prep:
	mkdir -p $(DIST_WORKDIR)
	cp -p $(DISTRIBUTE) $(DIST_WORKDIR)


dist-stable: dist-prep
	echo rsync $(DIST_WORKDIR)/. $(DIST_STABLE)/. -a --delete -z

