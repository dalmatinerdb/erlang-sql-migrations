-module(sql_migration).

-export([
         run/1,
         run/2,
         migrations/1,
         migrate/3,
         file/1
        ]).


-callback upgrade(Pool :: atom()) -> any().
-callback downgrade(Pool :: atom()) -> any().


file(Name) ->
    T = calendar:datetime_to_gregorian_seconds(
          calendar:now_to_universal_time(erlang:timestamp())) -
        calendar:datetime_to_gregorian_seconds( {{1970,1,1},{0,0,0}}),
    io:format("priv/schema/~p_~s.erl\n", [T, Name]).

run(App) ->
    Pool = application:get_env(sqlmig, pool, epgsql_pool),
    run(App, Pool).

run(App, Pool) ->
    case migrations(App) of
        [] ->
            ok;
        Migrations ->
            Version = lists:last(Migrations),
            migrate(Pool, Version, Migrations)
    end.

migrations(App) ->
    {ok, Ms} = application:get_key(App, modules),
    Migrations = [ M || M <- Ms, is_migration(M)],
    lists:usort(Migrations).

migrate(Pool, Version, Migrations) ->
    BinVersion = atom_to_binary(Version, latin1),
    case pgapp:squery(Pool, "SELECT id FROM migrations ORDER BY id DESC") of
        {error, {error, error, <<"42P01">>, _, _, _}} ->
            %% init migrations and restart
            init_migrations(Pool),
            migrate(Pool, Version, Migrations);
        {ok, _, [{BinVersion} | _]} ->
            up_to_date;
        {ok, _, [{Top} | _]} when Top < BinVersion ->
            %% upgrade path
            TopAtom = binary_to_atom(Top, latin1),
            Upgrade = lists:dropwhile(fun (V) -> V =< TopAtom end, Migrations),
            [upgrade(Migration, Pool) || Migration <- Upgrade],
            {upgrade, Upgrade};
        {ok, _, [{Top}|_]} when Top > BinVersion ->
            %% downgrade path
            TopAtom = binary_to_atom(Top, latin1),
            Downgrade = lists:takewhile(fun (V) -> V >= TopAtom end,
                                        lists:reverse(Migrations)),
            [downgrade(Migration, Pool) || Migration <- Downgrade],
            {downgrade, Downgrade};
        {ok, _, []} ->
            %% full upgrade path
            Upgrade = Migrations,
            [upgrade(Migration, Pool) || Migration <- Upgrade],
            {upgrade, Upgrade}
    end.


%% Private
upgrade(Migration, Pool) ->
    lager:info("[MIGRATION:~s] Running: ~s", [Pool, Migration]),
    Migration:upgrade(Pool),
    pgapp:equery(Pool,
                 "INSERT INTO migrations (id) "
                 "VALUES ($1)", [atom_to_binary(Migration, latin1)]).

downgrade(Migration, Pool) ->
    lager:info("[MIGRATION:~s] Rolling back: ~s", [Pool, Migration]),
    Migration:downgrade(Pool),
    pgapp:equery(Pool,
                 "DELETE FROM migrations WHERE id = $1",
                 [atom_to_binary(Migration, latin1)]).

init_migrations(Pool) ->
    lager:info("[MIGRATION:~s] Initializing migrations table.", [Pool]),
    {ok, _, _} = pgapp:squery(
                   Pool,
                   "CREATE TABLE migrations ("
                   "id VARCHAR(255) PRIMARY KEY,"
                   "datetime TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
                   ")").

is_migration(M) ->
    lists:member(sql_migration,
                 proplists:get_value(behaviour, M:module_info(attributes), [])).
