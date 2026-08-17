PANDOC ?= pandoc
PDF_ENGINE ?= xelatex
SOURCE ?= dconf2026.md
TARGET ?= $(SOURCE:.md=.pdf)

# Metropolis is clean but not anonymous: its strong typography works well for
# short technical talks. Pandoc's `pygments` is its supported colourized
# scheme. Use ```d fenced blocks for highlighted D source.
PANDOC_FLAGS := \
	--from=markdown \
	--to=beamer \
	--pdf-engine=$(PDF_ENGINE) \
	--syntax-highlighting=pygments \
	--slide-level=1 \
	--variable=aspectratio:169 \
	--variable=theme:metropolis \
	--variable=progressbar:frametitle

.DEFAULT_GOAL := $(TARGET)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(PANDOC) $(PANDOC_FLAGS) --output=$@ $<

clean:
	$(RM) -- $(TARGET)
