defmodule Alnasl.Support do
  @moduledoc """
  Support uploads: a box sends its diagnostics as a text file, gets a
  six-digit code back, and somebody reads the code out over the phone to
  whoever runs this installation's support, who finds the file under
  `/support`.

  ## Off unless somebody is named

  The whole thing is switched on by naming who may read the uploads:
  `ALNASL_SUPPORT_ADMINS`, comma-separated addresses (`:support_admins`).
  Nobody named, and the upload address refuses everything and `/support`
  is a 404 for everybody. That is the default, and the default of every
  box in a hall: support is something a server offers, and only the one
  whose operator decided to.

  ## Who may read

  `admin?/1`, and nothing else: an account whose address is on that list.
  Not the installation's admins (`ALNASL_ADMIN_EMAILS`), not a hall's
  owner. Running the server is one job and reading strangers' log files is
  another, and the list says who has the second.

  ## What is kept, and for how long

  The text, as text: valid UTF-8, no NUL bytes, at most `max_bytes/0`. A
  box has no secret to sign with (its image is public), so anybody can
  send anything, and everything sent is treated as a stranger's: shown
  escaped, offered as `text/plain` to download, never rendered as markup.
  The sender's address is kept only as a keyed hash, for the rate limit
  (`per_hour/0` uploads an address an hour). Uploads expire after
  `keep_days/0` days; expired ones are never shown and are deleted at the
  next upload or the next look at `/support`.
  """

  import Ecto.Query

  alias Alnasl.Repo
  alias Alnasl.Support.Upload

  @max_bytes 2 * 1024 * 1024
  @per_hour 5
  @keep_days 30
  @code_attempts 20

  @doc "The largest upload accepted, in bytes."
  def max_bytes, do: @max_bytes

  @doc "How many uploads one address may make in an hour."
  def per_hour, do: @per_hour

  @doc "How many days an upload is kept."
  def keep_days, do: @keep_days

  ## ---------- who ----------

  @doc "The addresses that may read support uploads (`ALNASL_SUPPORT_ADMINS`), lower case."
  def admins do
    for email <- Application.get_env(:alnasl, :support_admins, []),
        email = email |> String.trim() |> String.downcase(),
        email != "",
        do: email
  end

  @doc "Is support switched on here at all: is anybody named to read it?"
  def enabled?, do: admins() != []

  @doc """
  The one rule: may this account (a user, or a scope with one) read support
  uploads? Only when its address is on `admins/0`. Nobody signed in, a box
  without accounts, and everybody when the list is empty: no.
  """
  def admin?(%{user: user}), do: admin?(user)

  def admin?(%{email: email}) when is_binary(email),
    do: String.downcase(email) in admins()

  def admin?(_nobody), do: false

  ## ---------- receiving ----------

  @doc """
  Keeps `content` as a support upload and returns `{:ok, upload}` with its
  code, or `{:error, reason}`:

    * `:disabled` - nobody is named to read it (`enabled?/0`);
    * `:empty`, `:too_large`, `:not_text` - what was sent;
    * `:rate_limited` - this address sent `per_hour/0` in the last hour.

  `meta` may hold `:filename`, `:box_id`, `:version` and `:mode`, as the
  box said them; each is cut short and stripped of control characters.
  `ip` is the sender's address as text.

  Options, for tests: `:now`, and `:code` (a function giving the next
  candidate code).
  """
  def receive_upload(content, meta, ip, opts \\ []) when is_binary(content) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    ip_hash = ip_hash(ip)

    with :ok <- check_enabled(),
         :ok <- check_content(content),
         _ = purge_expired(now),
         :ok <- check_rate(ip_hash, now) do
      insert(content, meta, ip_hash, now, Keyword.get(opts, :code, &random_code/0))
    end
  end

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  @doc false
  def check_content(""), do: {:error, :empty}
  def check_content(content) when byte_size(content) > @max_bytes, do: {:error, :too_large}

  def check_content(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, :not_text}
  end

  defp check_rate(ip_hash, now) do
    since = DateTime.add(now, -3600)

    count =
      Repo.aggregate(
        from(u in Upload, where: u.ip_hash == ^ip_hash and u.inserted_at > ^since),
        :count
      )

    if count >= @per_hour, do: {:error, :rate_limited}, else: :ok
  end

  # Expired rows went in `purge_expired/1` just before, so a code is unique
  # among the uploads still alive, which is all a code has to be.
  defp insert(content, meta, ip_hash, now, next_code, attempt \\ 1) do
    changeset =
      %Upload{
        code: next_code.(),
        content: content,
        size: byte_size(content),
        filename: clean(meta[:filename], 200),
        box_id: clean(meta[:box_id], 100),
        version: clean(meta[:version], 50),
        mode: clean(meta[:mode], 50),
        ip_hash: ip_hash,
        expires_at: DateTime.add(now, @keep_days * 86_400),
        inserted_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:code)

    case Repo.insert(changeset) do
      {:ok, upload} ->
        {:ok, upload}

      {:error, %Ecto.Changeset{errors: [code: _]}} when attempt < @code_attempts ->
        insert(content, meta, ip_hash, now, next_code, attempt + 1)

      {:error, _changeset} ->
        {:error, :no_code}
    end
  end

  @doc "A random six-digit code, leading zeros kept."
  def random_code do
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # What a box says about itself: printable, short, or nothing.
  defp clean(nil, _max), do: nil

  defp clean(text, max) when is_binary(text) do
    text =
      if String.valid?(text),
        do: text |> String.replace(~r/[[:cntrl:]]/u, "") |> String.trim() |> String.slice(0, max),
        else: ""

    if text == "", do: nil, else: text
  end

  defp clean(_other, _max), do: nil

  # The sender's address, keyed with the endpoint's secret: enough to count
  # by, not enough to read the address back out of the database.
  defp ip_hash(ip) do
    key = Application.get_env(:alnasl, AlnaslWeb.Endpoint, [])[:secret_key_base] || "alnasl"
    :hmac |> :crypto.mac(:sha256, key, to_string(ip)) |> Base.encode16(case: :lower)
  end

  ## ---------- reading ----------

  @doc "The newest live uploads, without their text, newest first."
  def list_recent(limit \\ 50, now \\ DateTime.utc_now(:second)) do
    Repo.all(
      from u in Upload,
        where: u.expires_at > ^now,
        order_by: [desc: u.inserted_at, desc: u.id],
        limit: ^limit,
        select:
          struct(u, [
            :id,
            :code,
            :size,
            :filename,
            :box_id,
            :version,
            :mode,
            :inserted_at,
            :expires_at
          ])
    )
  end

  @doc "The live upload with this code, or nil."
  def get_live(code, now \\ DateTime.utc_now(:second))

  def get_live(code, now) when is_binary(code) do
    code = String.trim(code)

    if code =~ ~r/\A\d{6}\z/,
      do: Repo.one(from u in Upload, where: u.code == ^code and u.expires_at > ^now),
      else: nil
  end

  def get_live(_code, _now), do: nil

  @doc "Deletes every upload past its expiry; returns how many went."
  def purge_expired(now \\ DateTime.utc_now(:second)) do
    {count, _} = Repo.delete_all(from u in Upload, where: u.expires_at <= ^now)
    count
  end
end
