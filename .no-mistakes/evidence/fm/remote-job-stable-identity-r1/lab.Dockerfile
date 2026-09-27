FROM ruby:4.0.5-slim-trixie
RUN apt-get update -qq && apt-get install -y -qq procps python3 git locales >/dev/null && sed -i 's/^# *fr_FR.UTF-8/fr_FR.UTF-8/' /etc/locale.gen && locale-gen >/dev/null && rm -rf /var/lib/apt/lists/*
