# Homebrew Formula for OpenClacky

This directory contains the Homebrew formula for OpenClacky.

## For Maintainers: Publishing to Homebrew Tap

### One-time Setup

1. Create a GitHub repository named `homebrew-openclacky` (must start with `homebrew-`)
2. Push this formula to the repository

```bash
# In your GitHub account, create: homebrew-openclacky
git clone https://github.com/YOUR_USERNAME/homebrew-openclacky.git
cd homebrew-openclacky
cp /path/to/openclacky/homebrew/openclacky.rb ./Formula/openclacky.rb
git add Formula/openclacky.rb
git commit -m "Add openclacky formula"
git push origin main
```

### Update Formula for New Release

When you release a new version:

1. Download the new gem and calculate SHA256:
```bash
VERSION=0.6.1
wget https://rubygems.org/downloads/openclacky-${VERSION}.gem
shasum -a 256 openclacky-${VERSION}.gem
```

2. Update the formula in `homebrew-openclacky` repository:
- Update `url` with new version
- Update `sha256` with calculated hash
- Commit and push

3. Users can then upgrade:
```bash
brew update
brew upgrade openclacky
```

## For Users: Installation

```bash
# Add the tap (one-time)
brew tap YOUR_USERNAME/openclacky

# Install
brew install openclacky

# Or in one command
brew install YOUR_USERNAME/openclacky/openclacky
```

## Testing the Formula Locally

```bash
# Install from local formula
brew install --build-from-source ./homebrew/openclacky.rb

# Or test without installing
brew test ./homebrew/openclacky.rb
```

## Automation Script

For easier updates, use this script:

```bash
#!/bin/bash
# update_formula.sh

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "Usage: ./update_formula.sh VERSION"
  exit 1
fi

# Download gem
wget https://rubygems.org/downloads/openclacky-${VERSION}.gem -O /tmp/openclacky.gem

# Calculate SHA256
SHA256=$(shasum -a 256 /tmp/openclacky.gem | cut -d' ' -f1)

# Update formula
sed -i '' "s|url \".*\"|url \"https://rubygems.org/downloads/openclacky-${VERSION}.gem\"|" openclacky.rb
sed -i '' "s|sha256 \".*\"|sha256 \"${SHA256}\"|" openclacky.rb

echo "Formula updated to version ${VERSION}"
echo "SHA256: ${SHA256}"
echo "Don't forget to commit and push to homebrew-openclacky repository!"

rm /tmp/openclacky.gem
```
