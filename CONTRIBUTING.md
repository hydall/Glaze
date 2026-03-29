# 👋 Contribution guidelines

This document describes how to contribute to Glaze.

## 📖 Resources to help you get started

* [Issues](https://github.com/hydall/Glaze/issues) are where we keep track of bugs and feature requests

## 🙏 Submitting a feature request

Features can be requested by opening an issue. Please provide a clear description of the feature and the motivation behind it.

> [!NOTE]
> Requests can be accepted or rejected at the discretion of the maintainer.

## 🐞 Submitting a bug report

If you encounter a bug while using Glaze, open an issue and describe it. Include:

- Steps to reproduce
- Device and OS version
- Screenshots if applicable

## 📝 How to contribute

1. Before contributing, it is recommended to open an issue to discuss your change with the maintainer. This will help you determine whether your change is acceptable and whether it is worth your time to implement it.
2. Fork the repository and create your branch from `dev`.
3. Commit your changes.
4. Submit a pull request to the `dev` branch of the repository and reference issues that your pull request closes in its description.
5. The maintainer will review your pull request and provide feedback. Once your pull request is approved, it will be merged into the `dev` branch.

## 🛠️ Project Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/hydall/glaze.git
   cd glaze
   ```
3. Install dependencies:
   ```bash
   npm install
   ```
4. Start the dev server:
   ```bash
   npm run dev
   ```

## 🎨 Code Style

- **Vue 3** with Composition API (`<script setup>`)
- **JavaScript** — no TypeScript
- Single-file components (`.vue`)
- Reactive state via Vue's `reactive()` / `ref()` in `src/core/states/`
- Business logic in `src/core/services/`
- Reusable logic in `src/composables/`

❤️ Thank you for considering contributing to Glaze!
