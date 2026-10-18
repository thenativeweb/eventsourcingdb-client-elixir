defmodule EventSourcingDB.RawJSON do
  @moduledoc false

  # Finds values within JSON text and returns their text exactly as it
  # appears, byte for byte, without decoding and encoding them again. It
  # expects valid JSON, so it is only called on text that Jason has decoded
  # already.

  @whitespace [?\s, ?\t, ?\n, ?\r]

  # Returns the text of the member with the given key of the object that the
  # text holds, or nil if the text holds no object or the object no such
  # member.
  @spec member(binary() | nil, String.t()) :: binary() | nil
  def member(nil, _key), do: nil

  def member(json, key) do
    position = skip_whitespace(json, 0)

    case byte_at(json, position) do
      ?{ -> find_member(json, position + 1, key)
      _other -> nil
    end
  end

  # Returns the texts of the elements of the array that the text holds, or an
  # empty list if the text holds no array.
  @spec elements(binary()) :: [binary()]
  def elements(json) do
    position = skip_whitespace(json, 0)

    case byte_at(json, position) do
      ?[ -> collect_elements(json, position + 1, [])
      _other -> []
    end
  end

  defp find_member(json, position, key) do
    position = skip_whitespace(json, position)

    case byte_at(json, position) do
      ?" ->
        key_end = skip_string(json, position + 1)
        member_key = Jason.decode!(binary_part(json, position, key_end - position))
        value_start = skip_whitespace(json, skip_whitespace(json, key_end) + 1)
        value_end = skip_value(json, value_start)

        if member_key == key do
          binary_part(json, value_start, value_end - value_start)
        else
          find_next_member(json, value_end, key)
        end

      _other ->
        nil
    end
  end

  defp find_next_member(json, value_end, key) do
    after_value = skip_whitespace(json, value_end)

    case byte_at(json, after_value) do
      ?, -> find_member(json, after_value + 1, key)
      _other -> nil
    end
  end

  defp collect_elements(json, position, elements) do
    position = skip_whitespace(json, position)

    case byte_at(json, position) do
      ?] ->
        Enum.reverse(elements)

      _other ->
        value_end = skip_value(json, position)
        element = binary_part(json, position, value_end - position)
        after_value = skip_whitespace(json, value_end)

        case byte_at(json, after_value) do
          ?, -> collect_elements(json, after_value + 1, [element | elements])
          _other -> Enum.reverse([element | elements])
        end
    end
  end

  # Returns the position after the value that starts at the given position.
  defp skip_value(json, position) do
    case byte_at(json, position) do
      ?" -> skip_string(json, position + 1)
      ?{ -> skip_container(json, position + 1, 1)
      ?[ -> skip_container(json, position + 1, 1)
      _other -> skip_literal(json, position)
    end
  end

  # Returns the position after the closing quote of the string whose content
  # starts at the given position.
  defp skip_string(json, position) do
    {index, 1} = :binary.match(json, ["\"", "\\"], scope: scope(json, position))

    case byte_at(json, index) do
      ?\\ -> skip_string(json, index + 2)
      ?" -> index + 1
    end
  end

  # Returns the position after the end of the object or array whose content
  # starts at the given position, at the given depth of nesting.
  defp skip_container(json, position, depth) do
    {index, 1} = :binary.match(json, ["\"", "{", "[", "}", "]"], scope: scope(json, position))

    case byte_at(json, index) do
      ?" -> skip_container(json, skip_string(json, index + 1), depth)
      opening when opening in [?{, ?[] -> skip_container(json, index + 1, depth + 1)
      _closing when depth == 1 -> index + 1
      _closing -> skip_container(json, index + 1, depth - 1)
    end
  end

  # Numbers, true, false, and null end before the next delimiter or at the end
  # of the text.
  defp skip_literal(json, position) do
    case :binary.match(json, [",", "}", "]", " ", "\t", "\n", "\r"], scope: scope(json, position)) do
      {index, 1} -> index
      :nomatch -> byte_size(json)
    end
  end

  defp skip_whitespace(json, position) do
    case byte_at(json, position) do
      character when character in @whitespace -> skip_whitespace(json, position + 1)
      _other -> position
    end
  end

  defp byte_at(json, position) when position < byte_size(json), do: :binary.at(json, position)
  defp byte_at(_json, _position), do: nil

  defp scope(json, position), do: {position, byte_size(json) - position}
end
