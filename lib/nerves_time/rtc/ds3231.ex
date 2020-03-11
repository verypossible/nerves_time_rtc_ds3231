defmodule NervesTime.RTC.DS3231 do
  @moduledoc """
  DS3231 RTC implementation for NervesTime

  To configure NervesTime to use this module, update the `:nerves_time` application
  environment like this:

  ```elixir
  config :nerves_time, rtc: NervesTime.RTC.DS3231
  ```

  To override the default I2C bus, I2C address, or centuries one may:

  ```elixir
  rtc_opts = [
    address: 0x68,
    bus_name: "i2c-1",
    century: 2000
  ]
  config :nerves_time, rtc: {NervesTime.RTC.DS3231, rtc_opts}
  ```

  The `:century` option indicates to this library what century to choose when the DS3231's century
  bit is set to logic `0`. When the bit is logic `1` the cetury will be the value of `:century`
  plus 100. Internally the DS3231 will toggle its century bit when its years counter rolls over.

  Check the logs for error messages if the RTC doesn't appear to work.

  See https://datasheets.maximintegrated.com/en/ds/DS3231.pdf for implementation details.
  """

  @behaviour NervesTime.RealTimeClock

  require Logger

  alias Circuits.I2C
  alias NervesTime.RTC.DS3231.{Alarm, Control, Date, Status, Temperature}

  @default_address 0x68
  @default_bus_name "i2c-1"
  @default_century_0 2000

  @typedoc """
  A number representing a century.

  For example, 2000 or 2100.
  """
  @type century() :: integer()

  @typedoc false
  @type state :: %{
          address: I2C.address(),
          bus_name: String.t(),
          century_0: I2C.address(),
          century_1: I2C.address(),
          i2c: I2C.bus()
        }

  @impl NervesTime.RealTimeClock
  def init(args) do
    address = Keyword.get(args, :address, @default_address)
    bus_name = Keyword.get(args, :bus_name, @default_bus_name)

    with {:ok, i2c} <- I2C.open(bus_name) do
      century_0 = Keyword.get(args, :century_0, @default_century_0)

      state = %{
        address: address,
        bus_name: bus_name,
        century_0: century_0,
        century_1: century_0 + 100,
        i2c: i2c
      }

      {:ok, state}
    else
      {:error, _} = error ->
        error

      error ->
        {:error, error}
    end
  end

  @impl NervesTime.RealTimeClock
  def terminate(_state), do: :ok

  @impl NervesTime.RealTimeClock
  def set_time(state, date_data) do
    with {:ok, status_data} <- get_status(state.i2c, state.address),
         {:ok, date_bin} <- Date.encode(date_data, state.century_0, state.century_1),
         :ok <- I2C.write(state.i2c, state.address, [0x0F, date_bin]),
         :ok <- set_status(state.i2c, state.address, %{status_data | osc_stop_flag: 0}) do
      state
    else
      error ->
        _ = Logger.error("Error setting DS3231 RTC to #{inspect(date_data)}: #{inspect(error)}")
        state
    end
  end

  @impl NervesTime.RealTimeClock
  def get_time(state) do
    with {:ok, registers} <- I2C.write_read(state.i2c, state.address, <<0>>, 7),
         {:ok, time} <- Date.decode(registers, state.century_0, state.century_1) do
      {:ok, time, state}
    else
      any_error ->
        _ = Logger.error("DS3231 RTC not set or has an error: #{inspect(any_error)}")
        {:unset, state}
    end
  end

  @doc "Reads the status register."
  def get_status(i2c, address), do: get(i2c, address, 0x0F, 1, Status)

  @doc "Writes the status register."
  def set_status(i2c, address, status), do: set(i2c, address, 0x0F, status, Status)

  @doc "Reads the control register."
  def get_control(i2c, address), do: get(i2c, address, 0x0E, 1, Control)

  @doc "Writes the control register."
  def set_control(i2c, address, control), do: set(i2c, address, 0x0E, control, Control)
  @doc "Reads an alarm register."
  def get_alarm(i2c, address, 1 = _alarm_num), do: get(i2c, address, 0x07, 4, Alarm)
  def get_alarm(i2c, address, 2 = _alarm_num), do: get(i2c, address, 0x0B, 3, Alarm)

  @doc "Writes an alarm register."
  def set_alarm(i2c, address, %{seconds: _} = a1), do: set(i2c, address, 0x07, a1, Alarm)
  def set_alarm(i2c, address, a2), do: set(i2c, address, 0x0B, a2, Alarm)

  @doc "Reads the temperature register."
  def get_temperature(i2c, address), do: get(i2c, address, 0x11, 2, Temperature)

  defp set(i2c, address, offset, data, module) do
    with {:ok, bin} <- module.encode(data),
         :ok <- I2C.write(i2c, address, [offset, bin]) do
      :ok
    else
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end

  defp get(i2c, address, offset, length, module) do
    with {:ok, bin} <- I2C.write_read(i2c, address, <<offset>>, length),
         {:ok, data} <- module.decode(bin) do
      {:ok, data}
    else
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end
end
