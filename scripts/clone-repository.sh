#!/bin/bash

# Receive the repository URL and the directory name as arguments
REPO_URL=$1
DIR_PATH=$2

# create the directory if it doesn't exist
mkdir -p $DIR_PATH

# move to the specified directory
cd $DIR_PATH

# Clone the repository into the specified directory
git clone $REPO_URL

# Move the content of the cloned repository to the parent directory
REPO_NAME=$(basename $REPO_URL .git)
mv $REPO_NAME/* ./

# Move the hidden files (if any) to the parent directory
mv $REPO_NAME/.* ./

# Remove the now-empty directory
rm -rf $REPO_NAME