#! /usr/bin/env python
# -*- coding: utf-8 -*-

from fabric.api import *

# ===================  config  =======================

env.roledefs = {
    'compile': ['root@10.0.5.117:65422'],
    'L148': ['root@192.168.1.148:65422'],
}

# ====================================================

@roles('L148')
def dev():
    excludes = ['*.beam', '*.swp', 'etc', '.app', '*.so', '*.pyc',
                'deps', 'tests', 'basho_bench', 'log', 'data']
    excludes = ' '.join(['--exclude=' + ex for ex in excludes])
    sync = 'rsync -e "ssh -p 65422" -ptrtv --progress %s ./ root@%s:/disk/disk0/basho_bench/' % (excludes, env.host)
    local(sync)

@roles('L148')
def rep():
    sync = 'rsync -e "ssh -p 65422" -ptrtvaz --progress root@%s:/disk/disk0/basho_bench/tests ./' % (env.host)
    local(sync)
    local('rm tests/current && make all_results')
