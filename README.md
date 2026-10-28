# phpBB on Kubernetes — an example

> **This is an example, not production code.**
>
> It is the forum described in
> [Running phpBB on Kubernetes](https://www.paulbramhall.uk/running-phpbb-on-kubernetes-part-1/),
> built so that the files the posts quote can be read in full and
> copied. It has been simplified where the production version carries
> detail that is specific to one board and would not apply to yours.
>
> **It is not maintained.** There is no issue tracker, no support, and
> no release cadence. Use it as a reference, and take what you need
> from it. If it does not fit your forum, that is probably because it
> was written for one.
>
> **It is private.** It is the working repository for the forum the
> posts are about, and it is not a public example to fork. The posts
> quote every file in it, so the code is in the posts as well.
>
> The things it leaves out, and where to find them:
>
> | What | Where it is |
> |---|---|
> | The club assets, the logo and the extensions | The production repository |
> | The database name, the namespace and the cluster | The production repository |
> | The reasoning behind the OPcache tuning | The post, *The performance measurement* |
> | The reasoning behind the pool sizing | The post, *Pool sizing is a CPU calculation* |
> | The connection limit, and why the guard reads it from the values | The post, *The persistent connection limit* |
> | The migration from an older phpBB | The post, *The migration sequence* |

## What is here

```
app-code/phpbb/
├── Dockerfile
├── Makefile
├── docker-compose.yaml
├── config.php.template
├── healthcheck.php
├── nginx.conf.template
├── nginx/
│   ├── phpbb-install-location-installer.conf
│   └── phpbb-install-location-production.conf
└── scripts/
    ├── apply-club-logo.sh
    ├── check-session-index.php
    ├── container-init.sh
    ├── docker-entrypoint.sh
    ├── phpbb-cron.sh
    ├── phpbb-install.sh
    ├── render-nginx-config.sh
    └── verify.sh

deployment/environments/
└── values.yaml
```

Every file is referenced in the post, and the post explains why each
one is the way it is. The short version:

- The **Dockerfile** is a multi-stage build with two targets. The
  `installer` target keeps phpBB's `install/` directory so a board can
  be installed for the first time. The `production` target removes it,
  so a running forum cannot be reinstalled by anyone who reaches the
  web interface.
- **`config.php.template`** is not baked into the image. The entrypoint
  renders it at container start from the environment, so the same
  image works locally and in a cluster with no rebuild.
- **`nginx.conf.template`** is a template because the forum can be
  served from the root of a host or from a path prefix, and that is
  only known at run time.
- **`scripts/container-init.sh`** is the container's PID 1. It runs
  nginx and PHP-FPM, and it brings the container down if either of
  them dies, so that the platform restarts it.
- **`scripts/phpbb-install.sh`** runs phpBB's own CLI installer,
  non-interactively, from a YAML file rendered from the environment.
- **`healthcheck.php`** is the readiness check. It answers `/readyz`,
  and it checks the database, because a forum that cannot reach its
  database is not ready.
- **`scripts/verify.sh`** is the verification suite. It runs against a
  live container and checks the things that are easy to get quietly
  wrong. `make verify` runs it.
- **`scripts/phpbb-cron.sh`** is the scheduled-task entrypoint, which
  runs phpBB's own task runner once and exits.
- **`scripts/apply-club-logo.sh`** patches a site logo into the
  prosilver theme at build time, and fails the build if the rules it
  expects are not where it expects them.
- **`scripts/check-session-index.php`** checks the compound index on
  the session table by its columns rather than by its name.
- **`deployment/environments/values.yaml`** is the deployment values,
  with the names genericised. The `make verify` target reads the
  connection limit out of it.

## Running it

You need Docker, and about five minutes.

```sh
cd app-code/phpbb

# 1. Build the image.
docker compose build phpbb

# 2. Start the database and wait for it to be healthy.
docker compose up -d mariadb

# 3. Install the forum. Once, and only once.
docker compose --profile install run --rm --no-deps phpbb-installer

# 4. Run it.
docker compose up -d phpbb

# Or, with the Makefile:
#   make db-up && make install && make up

# 5. Check it.
curl -I http://127.0.0.1:8080/
```

The forum is at <http://127.0.0.1:8080>.

The `--no-deps` on step 3 matters. Without it, Compose starts the
database for the run and then stops it again afterwards, and the next
step has nothing to talk to.

### The database is fresh

The first `docker compose up -d mariadb` creates an empty MariaDB
volume and the installer builds a board in it. There is no data to
copy, and no existing board to point at.

That is partly a consequence of the project name, and the project name
is set in the compose file:

```yaml
# The project name.
#
# Docker Compose derives the project name from the directory the file
# is in, and this file lives in `app-code/phpbb`. That is not unique.
# Every phpBB stack in the world has a directory called
# `app-code/phpbb`, so every one of them would resolve to the project
# name `phpbb` and SHARE THIS STACK'S VOLUMES.
#
# That is not a theoretical problem. Two stacks on one machine end up
# with one database, and `docker compose down -v` on one of them
# deletes the other's data.
#
# Naming the project here means the volumes are `example-phpbb_*` and
# nothing else can touch them. The container names are prefixed for
# the same reason.
name: example-phpbb
```

If you rename the project, rename the container names to match. The
two mechanisms are independent, and it is worth having both.

To start completely afresh, including the database:

```sh
docker compose --profile install --profile cron down -v
docker compose up -d mariadb
```

That removes the volumes as well as the containers, and the next
install starts from nothing.

To run the scheduled tasks as well:

```sh
docker compose --profile cron up -d phpbb-cron
```

And to tear it all down, including the data:

```sh
docker compose --profile install --profile cron down -v
```

### The admin account

A clean install creates one administrator, and this example gives it
a known password so that you can log in without hunting for it.

| | The default |
|---|---|
| The username | `admin` |
| The password | `ChangeMe123!` |
| The email address | `admin@example.com` |

The username and the email address are the obvious ones. The password
is in the compose file, and it is a password rather than a placeholder
precisely so that it is obvious to the reader that it is a password
and not a thing to be left alone. phpBB hashes it with argon2id, so
the database holds a hash and not the password itself.

**Change it.** It is a default in a file, and it is the only account
on the board. Set it in the environment before you install:

```sh
PHPBB_ADMIN_NAME=your-name \
PHPBB_ADMIN_EMAIL=you@example.com \
PHPBB_ADMIN_PASSWORD='something better' \
docker compose --profile install run --rm --no-deps phpbb-installer
```

The values are passed to phpBB's own CLI installer, which creates the
account as part of the install. If you have already installed and
want to change them, the Administration Control Panel is the place —
the username, the email address and the password are all editable
there.

## Before you use it for something real

Four things in here are set to values that are fine for a local stack
and wrong for production.

**The pool size.** `pm.max_children` is 30 here, and it is sized from
the CPU limit rather than chosen. If you turn on the persistent
database connection, the pool size becomes the number of database
connections, and it has to stay below the limit on the database user.
The limit is set by the database operator, and its default is often
lower than you would expect. See *The persistent connection limit* in
the post.

The `Makefile` reads the limit out of `deployment/environments/values.yaml`
rather than taking it on the command line, so the check against the
pool cannot be run with a stale number:

**The CPU limit.** Nothing in this repository sets one, because a
Docker Compose file has no concept of a CPU limit. In Kubernetes the
limit is what sets your throughput ceiling, and the worker pool is
sized from it. Measure the cost of a request on your board and divide.

**The password.** The compose file has a default password in it, which
is fine for a local stack and terrible anywhere else. The production
version reads it from a secret. The default administrator account is
the only account on a clean board, so it is the one to change first.

**The `server_name`.** It is `_` here, which matches anything. In
production it has to be the real hostname, and it has to match the
`server_name` in the phpBB configuration and the `server_name` in the
database, or the board builds its links for the wrong host.

## A note on the phpBB version

The Dockerfile pins phpBB 3.3.19 and verifies its SHA256. If you
change the version, change both values, and check the checksum against
the release directory rather than trusting a copy from somewhere else:

<https://download.phpbb.com/pub/release/3.3/>
