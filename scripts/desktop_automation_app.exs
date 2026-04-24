Enum.reduce_while(IO.stream(:stdio, :line), :ok, fn line, _acc ->
  if String.trim(line) == "stop" do
    {:halt, :ok}
  else
    {:cont, :ok}
  end
end)