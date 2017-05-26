-module(sql_migration).

-export([migrations/1, migrate/3]).


-callback upgrade(Pool :: atom()) -> any().
-callback downgrade(Pool :: atom()) -> any().

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
    Migration:upgrade(Pool),
    pgapp:equery(Pool,
                 "INSERT INTO migrations (id) "
                 "VALUES ($1)", [atom_to_binary(Migration, latin1)]).

downgrade(Migration, Pool) ->
    Migration:downgrade(Pool),
    pgapp:equery(Pool,
                 "DELETE FROM migrations WHERE id = $1",
                 [atom_to_binary(Migration, latin1)]).

init_migrations(Pool) ->
    {ok, _, _} = pgapp:squery(
                   Pool,
                   "CREATE TABLE migrations ("
                   "id VARCHAR(255) PRIMARY KEY,"
                   "datetime TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
                   ")").

is_migration(M) ->
    lists:member(sql_migration,
                 proplists:get_value(behavior, M:module_info(attributes), [])).
