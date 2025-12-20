# Contributing to Epilog Zing Driver

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Development Setup

### Prerequisites

- macOS 12.0 or later
- Xcode Command Line Tools: `xcode-select --install`
- Swift 5.9 or later

### Building

```bash
# Clone the repo
git clone https://github.com/leftouterjoins/EpilogDriver.git
cd EpilogDriver

# Build debug version
swift build

# Run tests
swift test

# Build release
swift build -c release --arch arm64 --arch x86_64
```

## Code Style

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and small

## Commit Messages

Follow conventional commits format:

```
type(scope): description

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

Examples:
```
feat(raster): add 3D greyscale engraving support
fix(vector): correct HPGL path generation for circles
docs: update installation instructions
```

## Pull Request Process

1. **Fork** the repository
2. **Create** a feature branch from `main`
3. **Make** your changes
4. **Test** your changes thoroughly
5. **Commit** with clear messages
6. **Push** to your fork
7. **Open** a Pull Request

### PR Checklist

- [ ] Code builds without warnings
- [ ] All tests pass (`swift test`)
- [ ] New features have tests
- [ ] Documentation updated if needed
- [ ] Commit messages follow conventions

## Versioning

This project uses [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

To create a release:
```bash
git tag v1.2.3
git push origin v1.2.3
```

The GitHub Actions workflow will automatically build and publish the release.

## Testing

### Running Tests

```bash
# Run all tests
swift test

# Run specific test
swift test --filter RasterEncoderTests
```

### Testing with CUPS

```bash
# Test filter with a PDF
cupsfilter -p PPD/EpilogZing16.ppd \
  -m application/vnd.cups-raster \
  test.pdf > output.prn

# View CUPS debug logs
sudo cupsctl --debug-logging
tail -f /var/log/cups/error_log
```

## Architecture

### Key Components

| File | Purpose |
|------|---------|
| `main.swift` | CUPS filter entry point |
| `EpilogJob.swift` | Job orchestration |
| `RasterEncoder.swift` | PCL raster generation |
| `VectorEncoder.swift` | HPGL vector generation |
| `PJLGenerator.swift` | PJL header/footer |
| `CUPSRasterStream.swift` | CUPS raster input |

### Data Flow

```
PDF/Image → CUPS → rastertoepiloz → PJL/PCL/HPGL → Epilog Laser
                   (our filter)
```

## Reporting Issues

When reporting issues, please include:

- macOS version
- Epilog model and firmware
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs (`/var/log/cups/error_log`)

## Questions?

Open an issue with the "question" label or start a discussion.
