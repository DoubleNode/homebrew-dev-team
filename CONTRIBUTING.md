# Contributing to Dev-Team Homebrew Tap

Thank you for your interest in contributing to the Dev-Team Homebrew Tap!

## Development Setup

### Prerequisites

- macOS Big Sur or later
- Homebrew installed
- Git

### Clone the Tap

```bash
brew tap DoubleNode/dev-team
cd $(brew --repository DoubleNode/dev-team)
```

## Formula Development

### Testing Changes Locally

```bash
# Edit the formula
vim Formula/dev-team.rb

# Audit the formula
brew audit --strict --online Formula/dev-team.rb

# Install from source to test
brew install --build-from-source dev-team

# Run formula tests
brew test dev-team

# Test the actual commands
dev-team --version
dev-team-setup --help
dev-team-doctor --verbose

# Uninstall when done testing
brew uninstall dev-team
```

### Formula Style Guide

Follow Homebrew's formula style guide:
- Use Ruby 2.6+ syntax
- Keep formula class name in sync with filename
- Use double quotes for strings
- Indent with 2 spaces
- Keep dependencies alphabetically sorted

### Updating the Formula

When updating the formula for a new release:

1. **Update version number**
   ```ruby
   version "1.1.0"
   ```

2. **Update URL**
   ```ruby
   url "https://github.com/DoubleNode/dev-team/archive/refs/tags/v1.1.0.tar.gz"
   ```

3. **Calculate new SHA256**
   ```bash
   # Download the release tarball
   curl -L -o dev-team-1.1.0.tar.gz \
     https://github.com/DoubleNode/dev-team/archive/refs/tags/v1.1.0.tar.gz

   # Calculate SHA256
   shasum -a 256 dev-team-1.1.0.tar.gz

   # Update formula
   sha256 "new_sha256_hash_here"
   ```

4. **Test the updated formula**
   ```bash
   brew reinstall --build-from-source dev-team
   brew test dev-team
   ```

5. **Commit changes**
   ```bash
   git add Formula/dev-team.rb
   git commit -m "dev-team: update to version 1.1.0"
   git push origin main
   ```

## Core Scripts Development

### Editing CLI Scripts

Scripts are located in `bin/`:
- `dev-team-cli.sh` - Main CLI dispatcher
- `dev-team-setup.sh` - Setup wizard
- `dev-team-doctor.sh` - Health check and diagnostics

### Testing Scripts

```bash
# Check syntax
bash -n bin/dev-team-cli.sh
bash -n bin/dev-team-setup.sh
bash -n bin/dev-team-doctor.sh

# Run ShellCheck
brew install shellcheck
shellcheck bin/*.sh

# Make executable
chmod +x bin/*.sh

# Test directly
./bin/dev-team-cli.sh help
./bin/dev-team-setup.sh --help
./bin/dev-team-doctor.sh --version
```

## Testing

### Manual Testing Workflow

1. **Install from source**
   ```bash
   brew install --build-from-source dev-team
   ```

2. **Run setup wizard**
   ```bash
   dev-team setup
   ```

3. **Test all commands**
   ```bash
   dev-team --version
   dev-team help
   dev-team-setup --help
   dev-team-doctor
   dev-team-doctor --verbose
   dev-team-doctor --check dependencies
   ```

4. **Test upgrade path**
   ```bash
   dev-team setup --upgrade
   ```

5. **Test uninstall**
   ```bash
   dev-team setup --uninstall
   brew uninstall dev-team
   ```

### Automated Testing

GitHub Actions run automatically on:
- Push to `main` or `develop`
- Pull requests
- Manual trigger

Tests include:
- Formula audit
- Formula style check
- Installation on Intel and ARM macOS
- Script syntax validation
- ShellCheck linting

## Pull Request Process

1. **Fork the repository**

2. **Create a feature branch**
   ```bash
   git checkout -b feature/my-improvement
   ```

3. **Make your changes**
   - Update formula if needed
   - Update scripts if needed
   - Update documentation if needed

4. **Test your changes**
   ```bash
   brew audit --strict Formula/dev-team.rb
   brew install --build-from-source dev-team
   brew test dev-team
   ```

5. **Commit with descriptive message**
   ```bash
   git commit -m "feat: Add support for custom port configuration

   - Add --port option to dev-team-setup
   - Update health check to verify custom ports
   - Document port configuration in README"
   ```

6. **Push to your fork**
   ```bash
   git push origin feature/my-improvement
   ```

7. **Create pull request**
   - Describe what changed and why
   - Reference any related issues
   - Include testing notes

## Release Process

### Creating a New Release

1. **Update version in formula**
   ```ruby
   version "1.1.0"
   ```

2. **Tag the main dev-team repository**
   ```bash
   cd /path/to/dev-team
   git tag -a v1.1.0 -m "Release v1.1.0"
   git push origin v1.1.0
   ```

3. **GitHub will create release tarball**
   ```
   https://github.com/DoubleNode/dev-team/archive/refs/tags/v1.1.0.tar.gz
   ```

4. **Update formula SHA256**
   ```bash
   curl -L -o dev-team-1.1.0.tar.gz \
     https://github.com/DoubleNode/dev-team/archive/refs/tags/v1.1.0.tar.gz
   shasum -a 256 dev-team-1.1.0.tar.gz
   ```

5. **Update formula with new SHA256**

6. **Test thoroughly**
   ```bash
   brew uninstall dev-team
   brew install --build-from-source dev-team
   brew test dev-team
   dev-team setup  # Full integration test
   ```

7. **Commit and tag**
   ```bash
   git add Formula/dev-team.rb
   git commit -m "dev-team: update to version 1.1.0"
   git tag -a v1.1.0 -m "Formula v1.1.0"
   git push origin main
   git push origin v1.1.0
   ```

## Common Issues

### Formula Not Found After Changes

```bash
brew untap DoubleNode/dev-team
brew tap DoubleNode/dev-team
```

### Installation Fails

```bash
# Check formula syntax
brew audit Formula/dev-team.rb

# Install with verbose output
brew install --build-from-source --verbose dev-team
```

### Test Failures

```bash
# Check what test block expects
cat Formula/dev-team.rb | grep -A 20 "test do"

# Run test with verbose output
brew test --verbose dev-team
```

## Code Style

### Ruby (Formula)
- Follow Homebrew Formula Cookbook
- Use `rubocop` for linting
- 2-space indentation

### Bash (Scripts)
- Use `#!/bin/bash` shebang
- Enable `set -eo pipefail`
- Quote all variables
- Use `shellcheck` for linting
- Follow Google Shell Style Guide

### Documentation
- Use Markdown
- Keep lines under 100 characters
- Include code examples
- Update CHANGELOG.md

## Questions?

- Open an issue on GitHub
- Check existing issues/PRs for similar problems
- Review Homebrew documentation: https://docs.brew.sh/

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT).
