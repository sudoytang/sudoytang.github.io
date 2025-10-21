#!/bin/bash

# Build Zola site
echo "Building Zola site..."
zola build

# Check if build was successful
if [ ! -d "public" ]; then
    echo "Error: Build failed, public directory not found"
    exit 1
fi

# Enter public directory
cd public

# Initialize git repository (if it doesn't exist)
if [ ! -d ".git" ]; then
    git init
    git remote add origin https://github.com/sudoytang/sudoytang.github.io.git
fi

# Add all files
git add .

# Commit changes
git commit -m "Deploy: $(date)"

# Push to gh-pages branch
git push origin HEAD:gh-pages --force

echo "Deployment completed!"
