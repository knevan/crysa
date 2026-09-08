defmodule CrysaWeb.UserSettingsLiveTest do
  @moduledoc """
  Unit tests for the pure avatar-outcome resolver.

  Regression cover for the production crash where `save_avatar` matched
  `consume_uploaded_entries/3` results against `{:ok, ...}` tuples while the
  function actually returns unwrapped values — killing the LiveView AFTER the
  file had been stored (orphan in R2, NULL in the DB, no feedback shown).
  """

  use ExUnit.Case, async: true

  alias CrysaWeb.UserSettingsLive

  describe "resolve_avatar_outcome/2" do
    test "resolves a stored entry to its url" do
      consumed = [
        {:stored, %{key: "avatars/user_1_abc.jpg", url: "https://cdn.example/avatars/x.jpg"}}
      ]

      assert UserSettingsLive.resolve_avatar_outcome(consumed, []) ==
               {:saved, "https://cdn.example/avatars/x.jpg"}
    end

    test "resolves a storage failure to its message" do
      assert UserSettingsLive.resolve_avatar_outcome([{:storage_error, "boom"}], []) ==
               {:failed, "boom"}
    end

    test "resolves empty results without upload errors to missing file" do
      assert UserSettingsLive.resolve_avatar_outcome([], []) ==
               {:missing, "No file was uploaded."}
    end

    test "resolves an oversized entry to the size message" do
      assert UserSettingsLive.resolve_avatar_outcome([], [{"0", :too_large}]) ==
               {:failed, "The avatar must be 2 MB or smaller."}
    end

    test "resolves a rejected type to the allowlist message" do
      assert UserSettingsLive.resolve_avatar_outcome([], [{"0", :not_accepted}]) ==
               {:failed, "Only JPEG, PNG, WebP, and GIF images are allowed."}
    end
  end
end
