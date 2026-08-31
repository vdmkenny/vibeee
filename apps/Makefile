# Building the things that are not part of the system.
#
# One recipe per app in `<name>/app.mk`, saying where its source comes
# from and how to build it. Source is fetched into `build/apps/`, which
# is not tracked: what lives here is the recipe and the glue.
#
#   make -C apps              build every app
#   make -C apps APP=doom     build one

ROOT      := $(abspath ..)
FETCHED   := $(ROOT)/build/apps
STAGING   := $(ROOT)/home
EEECC     := $(ROOT)/tools/eeecc

APPS := $(patsubst %/app.mk,%,$(wildcard */app.mk))

.PHONY: all list clean $(APPS)

ifeq ($(APP),)

all: $(APPS)

$(APPS):
	@$(MAKE) --no-print-directory APP=$@ build

list:
	@for a in $(APPS); do echo "  $$a"; done

clean:
	@rm -rf $(FETCHED)

else

include $(APP)/app.mk

SRC := $(FETCHED)/$(APP)/$(SUBDIR)

.PHONY: build fetch

build: fetch
	@echo "  app     $(APP)"
	@mkdir -p $(STAGING)
	@cd $(SRC) && $(EEECC) $(CFLAGS) -I$(SRC) -o $(STAGING)/$(APP) \
		$(SOURCES) $(addprefix $(ROOT)/apps/$(APP)/,$(GLUE))
	@echo "  ready   home/$(APP), on the machine at the next image build"
	@# An app may need data that is nobody's to redistribute. Say what is
	@# missing and where it comes from, rather than fetching it on
	@# somebody's behalf or failing with nothing to go on.
	@for d in $(DATA); do \
		[ -e $(STAGING)/$$d ] && continue; \
		echo "  needs   home/$$d, which you fetch yourself:"; \
		echo "            curl -L -o home/$$d $(DATA_FROM)"; \
	done

# Fetched once and left alone. An app whose upstream moved is a
# deliberate `make -C apps clean` away, not something a build does to
# somebody in the middle of working.
fetch: $(SRC)

$(SRC):
	@echo "  fetch   $(APP) from $(SOURCE)"
	@mkdir -p $(FETCHED)
	@git clone --depth 1 --branch $(REF) $(SOURCE) $(FETCHED)/$(APP) 2>&1 | sed 's/^/          /'

endif
