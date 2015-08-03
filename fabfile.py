#! /usr/bin/env python
# -*- coding: utf-8 -*-

from fabric.api import *

# ===================  config  =======================

env.roledefs = {
    'compile': ['root@10.0.5.117:65422'],
    '111': ['root@10.0.5.111'],
    '112': ['root@10.0.5.112'],
    'A00': ['root@192.168.1.168:65422'],
    'L141': ['root@192.168.1.141:65422'],
    'L142': ['root@192.168.1.142:65422'],
    'A168': ['root@192.168.1.168:65422'],
}

# ====================================================

@roles('L141')
def dev():
    excludes = ['*.beam', '*.swp', 'etc', '.app', '*.so', '*.pyc',
                'deps', 'tests', 'basho_bench', 'log', 'data']
    excludes = ' '.join(['--exclude=' + ex for ex in excludes])
    sync = 'rsync -e "ssh -p 65422" -ptrtv --delete --progress %s ./ root@%s:/disk/disk0/basho_bench/' % (excludes, env.host)
    local(sync)
