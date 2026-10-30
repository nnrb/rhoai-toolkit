# BC RHOAI 폐쇄망 툴킷 - make 인터페이스(bc-toolkit.sh와 같은 명령)
#   make init | images | plan | install | verify | check
#   plan = dry-run install, install = 실제 적용(DRY_RUN=false, 단계별 확인 질문)
SHELL := /bin/bash
BASE := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: help init check images plan install verify bundle
help:
	@sed -n '1,4p' $(BASE)/Makefile

init:
	@bash $(BASE)/bc-toolkit.sh init

check:
	@bash $(BASE)/bc-toolkit.sh check

images:
	@bash $(BASE)/bc-toolkit.sh images

plan:
	@DRY_RUN=true bash $(BASE)/bc-toolkit.sh install

install:
	@DRY_RUN=false bash $(BASE)/bc-toolkit.sh install

verify:
	@bash $(BASE)/bc-toolkit.sh verify

# 인터넷 구간(git 있는 Linux)에서 반입용 git bundle 생성
bundle:
	@bash $(BASE)/tools/make-bundle.sh
