#! /bin/bash

set -e 

ppa="ppa:lkwg82/clever-backup"


gbp dch --release --git-author --commit --id-length=10 \
	&& gbp buildpackage -S -sa --git-tag --git-sign-tags --git-no-create-orig \
	&& dput $ppa $(find ../clever-backup*source.changes | sort | tail -n1) \
    && git push \
	&& git push origin --tags