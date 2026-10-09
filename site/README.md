# Oil Find website

The site uses Next.js App Router, React, and TypeScript. Use Node.js 22 and pnpm 11.

## Local development

From this directory, install dependencies and start the development server:

```sh
pnpm install --frozen-lockfile
pnpm dev
```

The Chinese home page is at `/`, the English home page is at `/en`, and each language has a changelog at `/changelog` or `/en/changelog`.

Run the checks and create a production build with:

```sh
pnpm test
pnpm typecheck
pnpm build
```

To serve a production build locally, run `pnpm start` after `pnpm build`.

## Pro licensing

The restored `/api` routes sell lifetime Oil Find Pro licenses. `/activated` and
`/recover` also have English versions under `/en`. The home page is unchanged;
the Pro purchase entry is part of M23.

Local fake payments never contact Stripe or Resend and use built-in development
keys when none are supplied:

```sh
STRIPE_FAKE=1 SITE_URL=http://127.0.0.1:8787 pnpm dev --port 8787
```

Fake payments are disabled in production even if `STRIPE_FAKE=1`. Next.js embeds
the production environment in the built server, so use `pnpm dev` for fake
payments. `pnpm start --port 8787` returns 404 for fake payments even with a
runtime `NODE_ENV=development` override.

`pnpm gen:keys` creates `.env.local` with mode 600, never reads or overwrites an
existing file, and prints only the public key. `mint-token.mjs` uses the supplied
process environment and does not load environment files. The deployment/key
setup scripts are restored for later release work; do not run them for local tests.

Production requires `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
`STRIPE_PRICE_LIFETIME`, `LICENSE_SIGNING_KEY`, `LICENSE_KEY_SECRET`, and `SITE_URL`.
For mail, also configure `RESEND_API_KEY` and `MAIL_FROM`; `MAIL_REPLY_TO` is optional.
The signing key must match the application's Pro public key. The Stripe price
must belong to Oil Find Pro and offer USD 19.99 with a CNY 99 currency option;
the supported payment methods are configured in Stripe during M23. No production
configuration is changed by this restoration.
