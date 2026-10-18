defmodule EventSourcingDBTest.RawJSON do
  alias EventSourcingDB.RawJSON
  use ExUnit.Case, async: true

  describe "member/2" do
    test "returns the text of a member exactly as it appears" do
      json = ~S({"id":"0","data":{"b":1e+21, "a" : [1, {"x":"y"}], "c":"Tom & Jerry"},"hash":"h"})

      assert RawJSON.member(json, "data") ==
               ~S({"b":1e+21, "a" : [1, {"x":"y"}], "c":"Tom & Jerry"})
    end

    test "skips members whose values hold brackets, quotes, and escapes in strings" do
      json =
        ~S({"a":"}]{[\"\\","b":{"c":"]}"},"d":[[],{}],"e":-1.5e-7,"f":true,"g":null,"data":42})

      assert RawJSON.member(json, "data") == "42"
      assert RawJSON.member(json, "a") == ~S("}]{[\"\\")
      assert RawJSON.member(json, "e") == "-1.5e-7"
      assert RawJSON.member(json, "g") == "null"
    end

    test "returns the text of a member at the end of the object, and allows whitespace" do
      json = " {\n \"type\" : \"event\" ,\r\n\t\"payload\" : {\"data\":{}} \n}\n"

      assert RawJSON.member(json, "payload") == ~S({"data":{}})
      assert json |> RawJSON.member("payload") |> RawJSON.member("data") == "{}"
    end

    test "finds a key whose name is escaped" do
      assert RawJSON.member(~S({"data":[1]}), "data") == "[1]"
    end

    test "returns nil for a missing member, for text that holds no object, and for nil" do
      assert RawJSON.member(~S({"id":"0"}), "data") == nil
      assert RawJSON.member(~S({}), "data") == nil
      assert RawJSON.member(~S([{"data":1}]), "data") == nil
      assert RawJSON.member(~S("data"), "data") == nil
      assert RawJSON.member(nil, "data") == nil
    end

    test "keeps multibyte characters" do
      json = ~S({"data":{"title":"2001 – A Space Odyssey €"}})

      assert RawJSON.member(json, "data") == ~S({"title":"2001 – A Space Odyssey €"})
    end
  end

  describe "elements/1" do
    test "returns the texts of the elements exactly as they appear" do
      json = ~S([{"data":{"a":"],["}}, {"data":[1,2]} ,3,"x",null])

      assert RawJSON.elements(json) ==
               [~S({"data":{"a":"],["}}), ~S({"data":[1,2]}), "3", ~S("x"), "null"]
    end

    test "returns no elements for an empty array, and for text that holds no array" do
      assert RawJSON.elements(" [ ] ") == []
      assert RawJSON.elements(~S({"a":1})) == []
    end
  end
end
