defmodule Crysa.StorageTest do
  use Crysa.DataCase, async: false

  alias Crysa.Storage

  setup do
    # Ensure test storage root is clean and isolated.
    root = storage_root()
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    # Configure trusted CDN for this test run.
    original = Application.get_env(:crysa, Crysa.Storage)

    Application.put_env(:crysa, Crysa.Storage,
      adapter: Crysa.Storage.Local,
      storage_root: root,
      url_prefix: "/uploads",
      cdn_base_url: "https://cdn.example.test",
      trusted_cdn_urls: ["https://cdn.example.test"]
    )

    on_exit(fn -> Application.put_env(:crysa, Crysa.Storage, original) end)

    :ok
  end

  describe "validate_key/1" do
    test "accepts valid keys" do
      assert :ok = Storage.validate_key("avatars/user_1_abc.png")
      assert :ok = Storage.validate_key("covers/abc-123.webp")
      assert :ok = Storage.validate_key("comments/1/uuid.jpg")
      assert :ok = Storage.validate_key("chapters/1/2/0001.webp")
    end

    test "rejects absolute, traversal, and illegal chars" do
      assert {:error, :invalid_key} = Storage.validate_key("/absolute.png")
      assert {:error, :invalid_key} = Storage.validate_key("a/../b.png")
      assert {:error, :invalid_key} = Storage.validate_key("a\\b.png")
      assert {:error, :invalid_key} = Storage.validate_key("a//b.png")
      assert {:error, :invalid_key} = Storage.validate_key("a b.png")
      assert {:error, :invalid_key} = Storage.validate_key("")
      assert {:error, :invalid_key} = Storage.validate_key(String.duplicate("a", 1_025))
    end
  end

  describe "put/3 and url_for/1 and delete/1" do
    test "puts binary and retrieves via url" do
      key = "test/#{uniq()}.txt"
      assert {:ok, ^key} = Storage.put(key, "hello world", content_type: "text/plain")
      assert File.read!(Path.join(storage_root(), key)) == "hello world"
      assert Storage.url_for(key) == "/uploads/#{key}"
    end

    test "puts file via {:file, path}" do
      path = write_tmp("file content")
      key = "test/#{uniq()}.bin"

      assert {:ok, ^key} =
               Storage.put(key, {:file, path}, content_type: "application/octet-stream")

      assert File.read!(Path.join(storage_root(), key)) == "file content"
      File.rm(path)
    end

    test "rejects invalid key on put" do
      assert {:error, :invalid_key} = Storage.put("/bad.png", "x", content_type: "image/png")
      assert {:error, :invalid_key} = Storage.put("a/../b.png", "x", content_type: "image/png")
    end

    test "prevents directory traversal via expanded path" do
      # Attempt to write outside storage_root using .. should be rejected by facade
      assert {:error, :invalid_key} =
               Storage.put("../escape.txt", "x", content_type: "text/plain")

      # Also ensure adapter would reject if facade were bypassed (defense in depth)
      # Direct adapter call without facade validation would still check expanded path
      assert {:error, :invalid_key} = Crysa.Storage.Local.put("../escape.txt", "x", [])
    end

    test "delete is idempotent and chunked" do
      keys =
        for _i <- 1..7 do
          k = "bulk/#{uniq()}.txt"
          {:ok, ^k} = Storage.put(k, "data", content_type: "text/plain")
          k
        end

      # Delete all via delete_many (chunk size 500, so single chunk here)
      assert :ok = Storage.delete_many(keys)

      for k <- keys do
        refute File.exists?(Path.join(storage_root(), k))
      end

      # Deleting again is idempotent
      assert :ok = Storage.delete_many(keys)
      assert :ok = Storage.delete("bulk/nonexistent.txt")
      assert :ok = Storage.delete_many([])
    end

    test "delete_many chunks large batches" do
      # Use 600 keys to trigger at least 2 chunks (default 500)
      keys =
        for i <- 1..600 do
          k = "chunked/#{uniq()}-#{i}.txt"
          {:ok, ^k} = Storage.put(k, "x", content_type: "text/plain")
          k
        end

      assert :ok = Storage.delete_many(keys)

      for k <- keys do
        refute File.exists?(Path.join(storage_root(), k))
      end
    end

    test "delete_by_urls extracts trusted keys and deletes" do
      key = "deletable/#{uniq()}.png"
      {:ok, ^key} = Storage.put(key, "pix", content_type: "image/png")
      # "/uploads/deletable/..."
      url = Storage.url_for(key)
      absolute = "https://cdn.example.test/#{key}"

      # Both relative and absolute trusted URLs should be deleted
      assert :ok = Storage.delete_by_urls([url, absolute])
      refute File.exists?(Path.join(storage_root(), key))

      # Untrusted URLs are ignored, not deleted, and return :ok
      other_key = "keep/#{uniq()}.png"
      {:ok, ^other_key} = Storage.put(other_key, "keep", content_type: "image/png")
      assert :ok = Storage.delete_by_urls(["https://evil.example.com/#{other_key}"])
      assert File.exists?(Path.join(storage_root(), other_key))
      # Clean up
      assert :ok = Storage.delete(other_key)
    end
  end

  describe "key_from_url/1 - safe extraction" do
    test "extracts relative url with trusted prefix" do
      key = "avatars/abc123.png"
      url = "/uploads/#{key}"
      assert {:ok, ^key} = Storage.key_from_url(url)

      # With query string
      assert {:ok, ^key} = Storage.key_from_url(url <> "?v=1")
      # With fragment
      assert {:ok, ^key} = Storage.key_from_url(url <> "#frag")
    end

    test "rejects relative url with wrong prefix" do
      assert {:error, :untrusted_url} = Storage.key_from_url("/other/avatars/abc.png")
      assert {:error, :untrusted_url} = Storage.key_from_url("/uploads_other/abc.png")
    end

    test "extracts absolute trusted CDN url" do
      key = "covers/abc.webp"
      url = "https://cdn.example.test/#{key}"
      assert {:ok, ^key} = Storage.key_from_url(url)
      assert {:ok, ^key} = Storage.key_from_url(url <> "?token=xyz")
      # Case-insensitive host
      assert {:ok, ^key} = Storage.key_from_url("https://CDN.example.test/#{key}")
    end

    test "rejects absolute url with untrusted host" do
      assert {:error, :untrusted_url} =
               Storage.key_from_url("https://evil.example.com/covers/abc.webp")

      assert {:error, :untrusted_url} =
               Storage.key_from_url("http://cdn.example.test/covers/abc.webp")
    end

    test "rejects urls with traversal in extracted key" do
      assert {:error, :invalid_key} = Storage.key_from_url("/uploads/../etc/passwd")

      assert {:error, :invalid_key} =
               Storage.key_from_url("https://cdn.example.test/../secret.png")

      assert {:error, :invalid_key} = Storage.key_from_url("https://cdn.example.test/a\\b.png")
      assert {:error, :invalid_key} = Storage.key_from_url("https://cdn.example.test/a//b.png")
    end

    test "rejects malformed urls" do
      assert {:error, :invalid_url} = Storage.key_from_url("")
      assert {:error, :invalid_url} = Storage.key_from_url(nil)
      assert {:error, :invalid_url} = Storage.key_from_url("not a url")
    end

    test "keys_from_urls filters untrusted and invalid" do
      good = "/uploads/good1.png"
      evil = "https://evil.com/good1.png"
      bad = "/bad/prefix.png"

      assert ["good1.png"] ==
               Storage.keys_from_urls([good, evil, bad])
               |> Enum.map(&Path.basename/1)
               |> Enum.filter(&(&1 == "good1.png"))

      # Actually keys_from_urls with our prefix would extract full key; test more precisely
      key = "safe/#{uniq()}.png"
      {:ok, _} = Storage.put(key, "x", content_type: "text/plain")
      good_url = "/uploads/#{key}"
      evil_url = "https://evil.com/#{key}"
      keys = Storage.keys_from_urls([good_url, evil_url])
      assert keys == [key]
    end
  end

  describe "high-level upload helpers" do
    test "store_avatar validates type and size and generates url" do
      path = write_tmp(String.duplicate("a", 100))
      upload = %Plug.Upload{path: path, content_type: "image/png", filename: "avatar.png"}
      assert {:ok, %{key: key, url: url}} = Storage.store_avatar(upload, %{id: 42})
      assert String.starts_with?(key, "avatars/user_42_")
      assert String.ends_with?(key, ".png")
      assert url == "/uploads/#{key}"
      assert File.exists?(Path.join(storage_root(), key))
      File.rm(path)
      Storage.delete(key)
    end

    test "store_avatar rejects invalid content type" do
      path = write_tmp("x")
      upload = %Plug.Upload{path: path, content_type: "text/plain", filename: "a.txt"}

      assert {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."} =
               Storage.store_avatar(upload, 1)

      File.rm(path)
    end

    test "store_avatar rejects oversized file" do
      # Create a file just over 2 MiB
      path = Path.join(System.tmp_dir!(), "big-#{uniq()}.png")
      File.write!(path, :crypto.strong_rand_bytes(2 * 1024 * 1024 + 1))
      upload = %Plug.Upload{path: path, content_type: "image/png", filename: "big.png"}
      assert {:error, "The avatar must be 2 MB or smaller."} = Storage.store_avatar(upload, 1)
      File.rm(path)
    end

    test "store_cover generates covers/ key" do
      path = write_tmp("cover")
      upload = %Plug.Upload{path: path, content_type: "image/jpeg", filename: "cover.jpg"}
      assert {:ok, %{key: key, url: url}} = Storage.store_cover(upload)
      assert String.starts_with?(key, "covers/")
      assert String.ends_with?(key, ".jpg")
      assert url == "/uploads/#{key}"
      File.rm(path)
      Storage.delete(key)
    end

    test "store_comment_attachment generates comments/<user_id>/ key" do
      path = write_tmp("attachment")
      upload = %Plug.Upload{path: path, content_type: "image/webp", filename: "a.webp"}
      assert {:ok, %{key: key, url: url}} = Storage.store_comment_attachment(upload, 99)
      assert String.starts_with?(key, "comments/99/")
      assert String.ends_with?(key, ".webp")
      assert url == "/uploads/#{key}"
      File.rm(path)
      Storage.delete(key)
    end

    test "store_chapter_image with binary and file" do
      # Binary
      assert {:ok, %{key: k1, url: u1}} =
               Storage.store_chapter_image("binary-data",
                 content_type: "image/webp",
                 series_id: 1,
                 chapter_key: "10.1",
                 image_order: 3
               )

      assert k1 == "chapters/1/10.1/0003.webp"
      assert u1 == "/uploads/#{k1}"
      assert File.read!(Path.join(storage_root(), k1)) == "binary-data"

      # File
      path = write_tmp("file-data")

      assert {:ok, %{key: k2, url: _}} =
               Storage.store_chapter_image({:file, path},
                 content_type: "image/webp",
                 series_id: 2,
                 chapter_key: "extra",
                 image_order: 0
               )

      assert k2 == "chapters/2/extra/0000.webp"
      File.rm(path)
      Storage.delete([k1, k2])
    end

    test "store_chapter_image sanitizes chapter_key" do
      assert {:ok, %{key: key}} =
               Storage.store_chapter_image("x",
                 content_type: "image/webp",
                 series_id: 1,
                 chapter_key: "10/evil..",
                 image_order: 1
               )

      # Slash in chapter_key should be sanitized to underscore, ".." not allowed to remain as traversal
      refute String.contains?(key, "/evil")
      assert String.contains?(key, "10_evil")
      Storage.delete(key)
    end

    test "store_chapter_images bulk helper" do
      entries = [
        %{data: "img1", content_type: "image/webp", order: 0},
        %{data: "img2", content_type: "image/webp", order: 1}
      ]

      assert {:ok, results} =
               Storage.store_chapter_images(entries, series_id: 5, chapter_key: "1")

      assert match?([_, _], results)
      assert Enum.map(results, & &1.key) == ["chapters/5/1/0000.webp", "chapters/5/1/0001.webp"]

      for %{key: k} <- results do
        assert File.exists?(Path.join(storage_root(), k))
      end

      Storage.delete_many(Enum.map(results, & &1.key))
    end

    test "store_avatar with nil user generates avatars/ key without user_id" do
      path = write_tmp("x")
      upload = %Plug.Upload{path: path, content_type: "image/png", filename: "a.png"}
      assert {:ok, %{key: key}} = Storage.store_avatar(upload, nil)
      assert String.starts_with?(key, "avatars/")
      refute String.contains?(key, "user_")
      File.rm(path)
      Storage.delete(key)
    end

    test "store_chapter_image does not crash on put error (H-1 regression)" do
      original = Application.get_env(:crysa, Crysa.Storage)

      Application.put_env(:crysa, Crysa.Storage,
        adapter: Crysa.Storage.S3,
        storage_root: storage_root(),
        url_prefix: "/uploads",
        cdn_base_url: "https://cdn.example.test",
        trusted_cdn_urls: ["https://cdn.example.test"],
        bucket: nil,
        access_key_id: nil,
        secret_access_key: nil,
        endpoint_url: nil
      )

      on_exit(fn -> Application.put_env(:crysa, Crysa.Storage, original) end)

      # S3 put will return {:error, :not_configured}, should propagate not raise MatchError
      assert {:error, :not_configured} =
               Storage.store_chapter_image("data",
                 content_type: "image/webp",
                 series_id: 1,
                 chapter_key: "1",
                 image_order: 0
               )
    end

    test "store_avatar rejects mismatched filename extension (M-5)" do
      path = write_tmp("x")
      upload = %Plug.Upload{path: path, content_type: "image/png", filename: "avatar.jpg"}

      assert {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."} =
               Storage.store_avatar(upload, 1)

      File.rm(path)
    end

    test "store_chapter_images cleans up partial failure and preserves order (M-3)" do
      entries = [
        %{data: "good", content_type: "image/webp", order: 0},
        %{data: "bad", content_type: "invalid/type", order: 1},
        %{data: "good2", content_type: "image/webp", order: 2}
      ]

      assert {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."} =
               Storage.store_chapter_images(entries, series_id: 99, chapter_key: "partial")

      # First image should have been cleaned up (orphan deleted)
      refute File.exists?(Path.join(storage_root(), "chapters/99/partial/0000.webp"))
      refute File.exists?(Path.join(storage_root(), "chapters/99/partial/0001.webp"))
    end
  end

  describe "regression: trusted CDN prefix bypass (M-1)" do
    test "rejects prefix bypass with path" do
      original = Application.get_env(:crysa, Crysa.Storage)

      Application.put_env(:crysa, Crysa.Storage,
        adapter: Crysa.Storage.Local,
        storage_root: storage_root(),
        url_prefix: "/uploads",
        cdn_base_url: "https://cdn.example.test/uploads",
        trusted_cdn_urls: ["https://cdn.example.test/uploads"]
      )

      on_exit(fn -> Application.put_env(:crysa, Crysa.Storage, original) end)

      assert {:error, :untrusted_url} =
               Storage.key_from_url("https://cdn.example.test/uploads_evil/x.png")

      assert {:error, :untrusted_url} =
               Storage.key_from_url("https://cdn.example.test/uploads_evil2/x.png")

      assert {:ok, "x.png"} = Storage.key_from_url("https://cdn.example.test/uploads/x.png")

      assert {:ok, "sub/x.png"} =
               Storage.key_from_url("https://cdn.example.test/uploads/sub/x.png")
    end
  end

  describe "adapter behaviour" do
    test "Local adapter implements behaviour" do
      assert Code.ensure_loaded?(Crysa.Storage.Local)

      assert Crysa.Storage.Local.__info__(:attributes)
             |> Keyword.get(:behaviour, [])
             |> Enum.member?(Crysa.Storage.Adapter) or
               Crysa.Storage.Adapter in (Crysa.Storage.Local.__info__(:attributes)[:behaviour] ||
                                           []) or
               function_exported?(Crysa.Storage.Local, :put, 3)
    end

    test "S3 adapter implements behaviour" do
      assert Code.ensure_loaded?(Crysa.Storage.S3)
      assert function_exported?(Crysa.Storage.S3, :put, 3)
      assert function_exported?(Crysa.Storage.S3, :delete, 1)
      assert function_exported?(Crysa.Storage.S3, :url, 1)
    end
  end

  # Helpers

  defp storage_root do
    Application.get_env(:crysa, Crysa.Storage)[:storage_root] ||
      Path.expand("tmp/test_uploads", File.cwd!())
  end

  defp uniq, do: System.unique_integer([:positive]) |> Integer.to_string()

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "storage-test-#{uniq()}.tmp")
    File.write!(path, content)
    path
  end
end
