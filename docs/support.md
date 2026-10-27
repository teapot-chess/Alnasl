# Support uploads

A box in trouble sends its diagnostics as a text file to a server and gets a
six-digit code back. The person at the box reads the code out to whoever
runs that server's support, who opens it on `/support`. Nobody has to email
a log file from a kiosk that has no email.

The receiving end is part of Alnasl itself, so any Alnasl server can be
somebody's support: the hosted one, or your own. It is off until you name
who may read the uploads.

## Turning it on

Set `ALNASL_SUPPORT_ADMINS` on the server to the addresses that may read
uploads, comma-separated:

```
ALNASL_SUPPORT_ADMINS=helpdesk@example.org,second-line@example.org
```

and restart. Those accounts (signed in the usual way, with a password or
02cloud) get **Support** in the Manage group of the menu, and `/support`.

Unset or empty, support is off: the upload address answers 404 to
everything without reading the body, and `/support` is a 404 for everybody.
That is the default, and what a box in a hall should keep.

The list is its own and not `ALNASL_ADMIN_EMAILS`. Running the server and
reading strangers' log files are two jobs; name the people who have the
second. Taking an address off the list (and restarting) shuts it out at
once, open page included: every event and every download asks again.

## Where boxes send

A box sends to whatever upload address it is configured with; nothing in
Alnasl points at one particular server. A self-hosted support desk gives its
boxes its own address, for example `https://alnasl.example.org/support/upload`.

## The upload API

`POST /support/upload` - no account, no session, no CSRF token.

Body, either:

* the file as the raw body, `Content-Type: text/plain; charset=utf-8`, or
* `multipart/form-data` with the file in the field `file`.

Optional headers, each kept as text and cut short:

| header | meaning | kept up to |
|---|---|---|
| `x-alnasl-box` | the box's id | 100 characters |
| `x-alnasl-version` | its Alnasl version | 50 |
| `x-alnasl-mode` | how it runs (kiosk, service, ...) | 50 |

Answers, all JSON:

| status | body | when |
|---|---|---|
| `201` | `{"code": "123456", "expires_at": "2026-11-25T12:00:00Z"}` | kept |
| `400` | `{"error": "empty"}` | no body, or an empty file |
| `413` | `{"error": "too_large"}` | over 2 MB (2,097,152 bytes) |
| `415` | `{"error": "not_text"}` | not valid UTF-8, contains a NUL byte, or sent as JSON or a urlencoded form |
| `429` | `{"error": "rate_limited"}`, `retry-after: 3600` | five uploads from this address in the last hour |
| `404` | `{"error": "not_found"}` | support is off on this server |

The code is six digits, leading zeros included, and no other upload still
kept holds it. Codes are a way to find an upload, not a key to it: only the
support admins can open one.

## What is kept, and for how long

* The text, as sent: valid UTF-8, no NUL bytes, at most 2 MB.
* What the box said about itself (the headers above), and the multipart
  file name.
* The sender's address only as a keyed hash, for the rate limit.

Thirty days after it arrived an upload is no longer shown, and the next
upload or the next visit to `/support` deletes it.

Anybody can post to the upload address: a box has no secret to sign with,
since its image is public. So everything that arrives is a stranger's text.
`/support` shows it inside a `<pre>`, escaped, and the download is served
as `text/plain` with `nosniff` and a sandboxing content security policy,
never as a page.

## Behind a proxy

The rate limit counts by the sender's address. Behind a Cloudflare tunnel
every request reaches Alnasl from the loopback address, so the sender is
read from `cf-connecting-ip` - but only on a request from the loopback
address, since anybody who could reach the port directly could write that
header too. Behind another proxy that does not set it, every sender looks
like the proxy and the limit is shared; keep the port itself off the
internet either way.

The body limit of a multipart form is Plug's (8 MB) before Alnasl's own
2 MB check refuses it; a raw body is read no further than one byte past
2 MB.
