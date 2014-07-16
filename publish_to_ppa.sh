#! /bin/bash

set -e 

git-dch --release --git-author --commit --id-length=10 \
	&& git-buildpackage -S -sa --git-tag --git-sign-tags --git-no-create-orig \
	&& echo dput ppa:lkwg82/clever-backup ../clever-backup-1_1-2ubuntu1_source.changes
