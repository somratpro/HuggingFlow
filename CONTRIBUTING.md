# Contributing to HuggingFlow

Thanks for your interest in contributing!

## How to contribute

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make your changes and test locally with `docker build .`
4. Commit with a clear message
5. Open a pull request describing what changed and why

## Development setup

You need Docker and a valid `LLM_MODEL` + `LLM_API_KEY` to test locally:

```bash
docker build -t huggingflow .
docker run --rm -p 7860:7860 \
  -e LLM_MODEL=openai/gpt-4o \
  -e LLM_API_KEY=sk-... \
  huggingflow
```

Open `http://localhost:7860` for the DeerFlow app,  
or `http://localhost:7860/dashboard` for the status dashboard.

## Guidelines

- Keep changes minimal and focused
- Test with at least one LLM provider before submitting
- Update `README.md` if you add new environment variables or features
- Open an issue first for large changes

## Reporting issues

Use [GitHub Issues](https://github.com/somratpro/HuggingFlow/issues).  
Include: what you expected, what happened, and your `LLM_MODEL` provider (no keys).
