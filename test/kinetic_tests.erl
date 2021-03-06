-module(kinetic_tests).

-include("kinetic.hrl").
-include_lib("eunit/include/eunit.hrl").



test_arg_setup(Opts) ->
    ets:new(?KINETIC_DATA, [named_table, set, public, {read_concurrency, true}]),
    meck:new(kinetic_utils, [passthrough]),
    meck:expect(kinetic_utils, fetch_and_return_url,
                fun(_MetaData, text) -> {ok, "us-east-1b"} end),

    {ok, _args} = kinetic_config:update_data(Opts),

    meck:new(lhttpc),
    meck:expect(lhttpc, request, fun
        (_Url, post, _Headers, _Body, _Timeout, error) ->
                {ok, {{400, bla}, headers, body}};
        (_Url, post, _Headers, _Body, _Timeout, _Opts) ->
                {ok, {{200, bla}, headers, <<"{\"hello\": \"world\"}">>}}
    end).

test_setup() ->
    Opts = [{aws_access_key_id, "whatever"},
            {aws_secret_access_key, "secret"},
            {metadata_base_url, "doesn't matter"}],
    test_arg_setup(Opts).

test_error_setup() ->
    Opts = [{aws_access_key_id, "whatever"},
            {aws_secret_access_key, "secret"},
            {metadata_base_url, "doesn't matter"},
            {lhttpc_opts, error}],
    test_arg_setup(Opts).



test_teardown(_) ->
    ets:delete(?KINETIC_DATA),
    meck:unload(kinetic_utils),
    meck:unload(lhttpc).

kinetic_test_() ->
    {inorder,
        {foreach,
            fun test_setup/0,
            fun test_teardown/1,
            [
                ?_test(test_normal_functions())
            ]
        }
    }.

kinetic_error_test_() ->
    {inorder,
        {foreach,
            fun test_error_setup/0,
            fun test_teardown/1,
            [
                ?_test(test_error_functions())
            ]
        }
    }.


sample_arglists(Payload) ->
    [[Payload],
     [Payload, []],
     [Payload, 12345],
     [Payload, [{timeout, 12345}]],
     [Payload, [{region, "us-east-1"}]],
     [Payload, [{region, "us-east-1"},
                {timeout, 12345}]]].


test_normal_functions() ->
    lists:foreach(fun (F) ->
           [{ok, [{<<"hello">>, <<"world">>}]} = erlang:apply(kinetic, F, Args)
             || Args <- sample_arglists([])]
        end,
        [create_stream, delete_stream, describe_stream, get_records, get_shard_iterator,
         list_streams, merge_shards, put_record, split_shard]
    ),

    lists:foreach(fun (F) ->
                {error, _} = erlang:apply(kinetic, F, [{whatever}])
        end,
        [create_stream, delete_stream, describe_stream, get_records, get_shard_iterator,
         list_streams, merge_shards, put_record, split_shard]
    ).

test_error_functions() ->
    {ok, _args} = kinetic_config:update_data([{aws_access_key_id, "whatever"},
                                              {aws_secret_access_key, "secret"},
                                              {metadata_base_url, "doesn't matter"},
                                              {lhttpc_opts, error}]),
    lists:foreach(fun (F) ->
                [{error, {400, headers, body}} = erlang:apply(kinetic, F, Args)
                 || Args <- sample_arglists([])]
        end,
        [create_stream, delete_stream, describe_stream, get_records, get_shard_iterator,
         list_streams, merge_shards, put_record, split_shard]
    ),
    ets:delete_all_objects(?KINETIC_DATA),
    lists:foreach(fun (F) ->
               [{error, missing_credentials} = erlang:apply(kinetic, F, Args)
                 || Args <- sample_arglists([])]
        end,
        [create_stream, delete_stream, describe_stream, get_records, get_shard_iterator,
         list_streams, merge_shards, put_record, split_shard]
    ).

put_records_test_() ->
    {setup,
     fun test_setup/0,
     fun test_teardown/1,
     fun test_put_records/0
    }.

test_put_records() ->
    %% Test successful puts
    meck:expect(lhttpc, request, fun
        (_Url, post, _Headers, _Body, _Timeout, error) ->
                {ok, {{400, bla}, headers, body}};
        (_Url, post, _Headers, _Body, _Timeout, _Opts) ->
            {ok, {{200, bla}, headers, <<"{\"FailedRecordCount\": 1,
                    \"Records\":
                        [{\"SequenceNumber\": \"10\", \"ShardId\": \"5\" },
                         {\"ErrorCode\": \"404\", \"ErrorMessage\": \"Not found\"}]}">>}} end),

    {ok, SuccessfulRecords, FailedRecords} = erlang:apply(kinetic, put_records, [[]]),
    ?assertEqual([{<<"10">>, <<"5">>}], SuccessfulRecords),
    ?assertEqual([{<<"404">>, <<"Not found">>}], FailedRecords),

    %% test error on no successful puts
    meck:expect(lhttpc, request, fun
        (_Url, post, _Headers, _Body, _Timeout, error) ->
                {ok, {{400, bla}, headers, body}};
        (_Url, post, _Headers, _Body, _Timeout, _Opts) ->
            {ok, {{200, bla}, headers, <<"{\"FailedRecordCount\": 1,
                    \"Records\":
                        [{\"ErrorCode\": \"404\", \"ErrorMessage\": \"Not found\"}]}">>}} end),

    Expectedfailure = {error, {all_records_failed, [{<<"404">>, <<"Not found">>}]}},
    ?assertEqual(Expectedfailure, erlang:apply(kinetic, put_records, [[]])).
