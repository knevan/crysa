defmodule Crysa.Processing.CheckScheduleTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Processing.CheckSchedule

  describe "base_interval_minutes/1" do
    test "manual override wins over status defaults" do
      series = %{manual_check_interval_minutes: 720, publication_status: "ongoing"}
      assert CheckSchedule.base_interval_minutes(series) == 720
    end

    test "status-derived defaults" do
      assert CheckSchedule.base_interval_minutes(%{
               manual_check_interval_minutes: nil,
               publication_status: "ongoing"
             }) in 75..120

      assert CheckSchedule.base_interval_minutes(%{
               manual_check_interval_minutes: nil,
               publication_status: "hiatus"
             }) == 240

      assert CheckSchedule.base_interval_minutes(%{
               manual_check_interval_minutes: nil,
               publication_status: "completed"
             }) == 1_440
    end

    test "discontinued is unscheduled" do
      assert CheckSchedule.base_interval_minutes(%{
               manual_check_interval_minutes: nil,
               publication_status: "discontinued"
             }) == nil
    end
  end

  describe "backoff_multiplier/1" do
    test "doubles per failure and caps at x32" do
      assert CheckSchedule.backoff_multiplier(0) == 1
      assert CheckSchedule.backoff_multiplier(1) == 2
      assert CheckSchedule.backoff_multiplier(3) == 8
      assert CheckSchedule.backoff_multiplier(5) == 32
      assert CheckSchedule.backoff_multiplier(50) == 32
    end
  end

  describe "next_check_at/3" do
    @now ~U[2026-08-21 12:00:00Z]

    test "ongoing without failures lands within the jittered base window" do
      series = %{
        manual_check_interval_minutes: nil,
        publication_status: "ongoing",
        check_retry_count: 0
      }

      next = CheckSchedule.next_check_at(@now, series)
      minutes = DateTime.diff(next, @now, :second) / 60

      # 75..120 ±10% jitter
      assert minutes >= 60 and minutes <= 135
    end

    test "failures multiply the interval" do
      series = %{
        manual_check_interval_minutes: 60,
        publication_status: "ongoing",
        check_retry_count: 2
      }

      next = CheckSchedule.next_check_at(@now, series, jitter?: false)
      minutes = DateTime.diff(next, @now, :second) / 60

      assert minutes == 240
    end

    test "discontinued returns nil" do
      series = %{
        manual_check_interval_minutes: nil,
        publication_status: "discontinued",
        check_retry_count: 0
      }

      assert CheckSchedule.next_check_at(@now, series) == nil
    end

    test "jitter can be disabled for deterministic assertions" do
      series = %{
        manual_check_interval_minutes: 120,
        publication_status: "ongoing",
        check_retry_count: 0
      }

      next = CheckSchedule.next_check_at(@now, series, jitter?: false)
      assert next == DateTime.add(@now, 120 * 60, :second)
    end
  end
end
