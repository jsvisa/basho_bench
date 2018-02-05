#! /usr/bin/env python
# -*- coding: utf-8 -*-

from fabric.api import *

# ===================  config  =======================

env.roledefs = {
    'bench': ['root@10.20.1.1:1579'],
}

# ====================================================

@roles('bench')
def dev():
    excludes = ['*.beam', '.git', '*.swp', 'etc', '.app', '*.so', '*.pyc',
                'deps', 'tests', 'basho_bench', 'log', 'logs', 'data']
    excludes = ' '.join(['--exclude=' + ex for ex in excludes])
    sync = 'rsync -e "ssh -p 1579" -ptrtv --delete --progress %s ./ root@%s:/root/basho_bench/' % (excludes, env.host)
    local(sync)

@roles('bench')
def results():
    sync = 'rsync -e "ssh -p 1579" -ptrtvaz --delete --progress root@%s:/basho_bench/tests ./' % (env.host)
    local(sync)
    local('rm tests/current && make all_results')
