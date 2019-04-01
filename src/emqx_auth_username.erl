%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_auth_username).

-include_lib("emqx/include/emqx.hrl").

%% CLI callbacks
-export([cli/1]).

-export([is_enabled/0]).

-export([ add_user/2
        , update_password/2
        , remove_user/1
        , lookup_user/1
        , all_users/0
        ]).

-export([ init/1
        , check/2
        , description/0
        ]).

-export([unwrap_salt/1]).

-define(TAB, ?MODULE).

-define(UNDEFINED(S), (S =:= undefined)).

-record(?TAB, {username, password}).

%%-----------------------------------------------------------------------------
%% CLI
%%-----------------------------------------------------------------------------

cli(["list"]) ->
    if_enabled(fun() ->
        Usernames = mnesia:dirty_all_keys(?TAB),
        [emqx_cli:print("~s~n", [Username]) || Username <- Usernames]
    end);

cli(["add", Username, Password]) ->
    if_enabled(fun() ->
        Ok = add_user(iolist_to_binary(Username), iolist_to_binary(Password)),
        emqx_cli:print("~p~n", [Ok])
    end);

cli(["update", Username, NewPassword]) ->
    if_enabled(fun() ->
        Ok = update_password(iolist_to_binary(Username), iolist_to_binary(NewPassword)),
        emqx_cli:print("~p~n", [Ok])
    end);

cli(["del", Username]) ->
    if_enabled(fun() ->
        emqx_cli:print("~p~n", [remove_user(iolist_to_binary(Username))])
    end);

cli(_) ->
    emqx_cli:usage([{"users list", "List users"},
                    {"users add <Username> <Password>", "Add User"},
                    {"users update <Username> <NewPassword>", "Update User"},
                    {"users del <Username>", "Delete User"}]).

if_enabled(Fun) ->
    case is_enabled() of true -> Fun(); false -> hint() end.

hint() ->
    emqx_cli:print("Please './bin/emqx_ctl plugins load emqx_auth_username' first.~n").

%%-----------------------------------------------------------------------------
%% API
%%-----------------------------------------------------------------------------

is_enabled() ->
    lists:member(?TAB, mnesia:system_info(tables)).

%% @doc Add User
-spec(add_user(binary(), binary()) -> ok | {error, any()}).
add_user(Username, Password) ->
    User = #?TAB{username = Username, password = encrypted_data(Password)},
    ret(mnesia:transaction(fun insert_user/1, [User])).

insert_user(User = #?TAB{username = Username}) ->
    case mnesia:read(?TAB, Username) of
        []    -> mnesia:write(User);
        [_|_] -> mnesia:abort(existed)
    end.

%% @doc Update User
-spec(update_password(binary(), binary()) -> ok | {error, any()}).
update_password(Username, NewPassword) ->
    User = #?TAB{username = Username, password = encrypted_data(NewPassword)},
    ret(mnesia:transaction(fun do_update_password/1, [User])).

do_update_password(User = #?TAB{username = Username}) ->
    case mnesia:read(?TAB, Username) of
        [_|_] -> mnesia:write(User);
        [] -> mnesia:abort(noexisted)
    end.

add_default_user({Username, Password}) when is_atom(Username) ->
    add_default_user({atom_to_list(Username), Password});

add_default_user({Username, Password}) ->
    add_user(iolist_to_binary(Username), iolist_to_binary(Password)).

%% @doc Lookup user by username
-spec(lookup_user(binary()) -> list()).
lookup_user(Username) ->
    mnesia:dirty_read(?TAB, Username).

%% @doc Remove user
-spec(remove_user(binary()) -> ok | {error, any()}).
remove_user(Username) ->
    ret(mnesia:transaction(fun mnesia:delete/1, [{?TAB, Username}])).

ret({atomic, ok})     -> ok;
ret({aborted, Error}) -> {error, Error}.

%% @doc All usernames
-spec(all_users() -> list()).
all_users() -> mnesia:dirty_all_keys(?TAB).

init(Userlist) ->
    ok = ekka_mnesia:create_table(?TAB, [
            {disc_copies, [node()]},
            {attributes, record_info(fields, ?TAB)}]),
    ok = ekka_mnesia:copy_table(?TAB, disc_copies),
    ok = lists:foreach(fun add_default_user/1, Userlist).

check(Credentials = #{username := Username, password := Password}, _State)
    when ?UNDEFINED(Username); ?UNDEFINED(Password) ->
    {ok, Credentials#{auth_result => bad_username_or_password}};
check(Credentials = #{username := Username, password := Password}, #{hash_type := HashType}) ->
    case mnesia:dirty_read(?TAB, Username) of
        [] -> ok;
        [#?TAB{password = <<Salt:4/binary, Hash/binary>>}] ->
            case Hash =:= hash(Password, Salt, HashType) of
                true -> {stop, Credentials#{auth_result => success}};
                false -> {stop, Credentials#{auth_result => password_error}}
            end
    end.

unwrap_salt(<<_Salt:4/binary, HashPasswd/binary>>) ->
    HashPasswd.

description() ->
    "Username password Authentication Module".

%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

encrypted_data(Password) ->
    HashType = application:get_env(emqx_auth_username, password_hash, sha256),
    SaltBin = salt(),
    <<SaltBin/binary, (hash(Password, SaltBin, HashType))/binary>>.

hash(Password, SaltBin, HashType) ->
    emqx_passwd:hash(HashType, <<SaltBin/binary, Password/binary>>).

salt() ->
    rand:seed(exsplus, erlang:timestamp()),
    Salt = rand:uniform(16#ffffffff), <<Salt:32>>.
