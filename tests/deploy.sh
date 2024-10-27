#!/bin/bash

set -e
set -u

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DEPLOY_DIR=${SCRIPT_DIR}/../.vercel/output

rm -rf $DEPLOY_DIR
mkdir $DEPLOY_DIR

cp ${SCRIPT_DIR}/index.html $DEPLOY_DIR
cp ${SCRIPT_DIR}/*.webm $DEPLOY_DIR
