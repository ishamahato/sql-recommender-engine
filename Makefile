# Every target is a thin wrapper over a Python entry point or docker compose.
# Configuration lives in .env, never in flags on these lines.

PYTHON := .venv/bin/python
PIP    := .venv/bin/pip

.PHONY: help setup up down logs psql generate build refresh evaluate benchmark api dashboard test clean all

help:
	@echo "SQL Recommendation Engine"
	@echo ""
	@echo "  make setup      create the virtualenv and install dependencies"
	@echo "  make up         start PostgreSQL in Docker"
	@echo "  make generate   generate the synthetic dataset into data/"
	@echo "  make build      schema, load, indexes, views, similarity, ranker"
	@echo "  make evaluate   temporal evaluation against held out purchases"
	@echo "  make benchmark  index before and after timings"
	@echo "  make api        start the FastAPI service"
	@echo "  make dashboard  start the Streamlit dashboard"
	@echo "  make test       run the test suite"
	@echo "  make all        setup, up, generate, build, evaluate, benchmark"
	@echo ""
	@echo "  make down       stop PostgreSQL"
	@echo "  make psql       open a psql shell, pager off, using .env"
	@echo "  make clean      remove the generated dataset and caches"

setup:
	python3 -m venv .venv
	$(PIP) install -q -U pip
	$(PIP) install -q -r requirements.txt
	@test -f .env || cp .env.example .env
	@echo "Environment ready. Edit .env if your database is not on localhost:5433."

up:
	docker compose up -d
	@echo "Waiting for PostgreSQL to accept connections"
	@until docker compose exec -T postgres pg_isready -U recsys -d recsys >/dev/null 2>&1; do sleep 1; done
	@echo "PostgreSQL is ready on localhost:5433"

down:
	docker compose down

logs:
	docker compose logs -f postgres

# Connects using whatever .env points at, so this works against the Docker
# service and against a local PostgreSQL alike. The pager is turned off: psql
# otherwise opens results in less, which traps you at an (END) prompt until you
# press q.
psql:
	@set -a; . ./.env; set +a; \
	PGHOST=$$DB_HOST PGPORT=$$DB_PORT PGUSER=$$DB_USER \
	PGPASSWORD=$$DB_PASSWORD PGDATABASE=$$DB_NAME \
	psql -P pager=off

generate:
	$(PYTHON) -m python.generate_data

build:
	$(PYTHON) -m python.pipeline

refresh:
	$(PYTHON) -c "from python.pipeline import refresh; refresh()"

evaluate:
	$(PYTHON) -m python.evaluate

benchmark:
	$(PYTHON) -m python.benchmark

api:
	$(PYTHON) -m api.main

dashboard:
	.venv/bin/streamlit run dashboard/app.py

test:
	$(PYTHON) -m pytest tests -q

clean:
	rm -f data/*.csv
	rm -rf .pytest_cache __pycache__ python/__pycache__ api/__pycache__ tests/__pycache__

all: setup up generate build evaluate benchmark
	@echo ""
	@echo "Everything is built. Next:"
	@echo "  make api        then open http://127.0.0.1:8000/docs"
	@echo "  make dashboard  then open http://localhost:8501"
