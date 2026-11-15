#!/bin/sh

# record the commit that is being packaged, so selfUpdate.sh can tell whether
# a newer version is available
if git rev-parse HEAD >/dev/null 2>&1
then
    git rev-parse HEAD > src/usr/local/kobocloud/version
fi

tar -cvzf KoboRoot.tgz -C src etc usr
