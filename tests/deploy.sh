#!/bin/bash

set -e
set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEPLOY_DIR=${SCRIPT_DIR}/.vercel/output
REPORT_DIR=${SCRIPT_DIR}/report

rm -rf $DEPLOY_DIR
mkdir $DEPLOY_DIR

cp -r $REPORT_DIR/* $DEPLOY_DIR
