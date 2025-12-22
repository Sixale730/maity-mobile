# Contributing to Maity

Thank you for your interest in contributing to Maity! This document provides guidelines for contributing to the project.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/omi.git
   cd omi
   ```
3. **Set up the development environment**:
   ```bash
   cp .env.template .env
   # Edit .env with your API keys
   flutter pub get
   ```

## Development Workflow

1. **Create a branch** for your feature or fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following our coding standards

3. **Test your changes**:
   ```bash
   flutter analyze
   flutter test
   ```

4. **Commit your changes** with a clear message:
   ```bash
   git commit -m "feat: add new feature description"
   ```

5. **Push to your fork** and submit a Pull Request

## Commit Message Guidelines

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, etc.)
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

## Code Standards

- Follow the existing code style
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions small and focused
- Write tests for new features

## Pull Request Process

1. Update documentation if needed
2. Ensure all tests pass
3. Request review from maintainers
4. Address any feedback

## Reporting Issues

When reporting issues, please include:

- A clear description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Device/OS information
- Screenshots if applicable

## Questions?

Feel free to open an issue for any questions about contributing.

Thank you for helping improve Maity!
