#!/bin/bash

since="$1"
if [[ -z $since ]] ; then
	since="$(git describe --abbrev=0 HEAD^).."
fi

echo >> CHANGELOG
echo >> CHANGELOG
echo -n "# " >> CHANGELOG
git describe --abbrev=0 HEAD --tags >> CHANGELOG
git log --reverse --pretty=format:'* %s, @%aN)' "$since" >> CHANGELOG

git add CHANGELOG
git commit -m 'updated changelog' CHANGELOG
