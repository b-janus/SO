
-module(tateti).
-compile(export_all).


%% Creacion de la partida. Responde a games con el nombre del
%% jugador que la creo y se sigue con phase 2
ttt_phase1(IdProcP1) ->
    case services:name_by_psock(IdProcP1) of
        {ok,NameP1} ->
            receive
                {get_dets,GID} ->
                    IdProcP1 ! {add,play,GID},
                    games ! {ok,NameP1},
                    ttt_phase2(IdProcP1,NameP1,GID);
                error -> error
            end;
        {error,R} ->
            games ! {error,R}
    end.


%% Espera a que un jugador acceda a la partida creada
%% Si todo va bien se entra en el juego (phase 3)
%% Si el jugador que responde no esta en la lista,
%% se vuelve a esperar a otro jugador, y se rechaza al primero
ttt_phase2(IdProcP1,NameP1,GID) ->
    receive
       {access,Ret,IdProcP2} ->
            case services:name_by_psock(IdProcP2) of
                {ok,NameP2} ->
                    IdProcP2 ! {add,play,GID},
                    Ret ! {ok, NameP1 ++ " " ++ NameP2},
                    IdProcP1 ! {updt, GID ++ " ACCEPTED " ++ NameP2},
                    games ! {cstate,GID,full},
                    Tab = [0,0,0,0,0,0,0,0,0], % Tablero de juego vacio
                    Turn = random:uniform(2), % Primer turno
                    ttt_phase3([IdProcP1,IdProcP2],[NameP1,NameP2],
                               Tab, Turn, [], GID, 1);
                {error,R} ->
                    Ret ! {error,R},
                    ttt_phase2(IdProcP1,NameP1,GID)
            end
    end.


%% Ayuda para recibir solo mensajes que sean watch y unwatch
%% Se retorna la lista de los nuevos observadores y la de 
%% los que dejan de observar
watch_list(Wtcs,Out,Info) ->
    receive
        {watch,Ret,IdProc} ->
            Ret ! {ok,Info},
            IdProc ! {add,watch,GID},
            watch_list([IdProc|Wtcs],Out,Info);
        {unwatch,Ret,IdProc} ->
            Ret ! {ok,""},
            IdProc ! {del,watch,GID},
            watch_list(Wtcs,[IdProc|Out],Info)
    after 0 ->
        {Wtcs,Out}
    end.


%% Broadcast de Msg para todo elemento en Receivers
updt_bcast(Msg,Receivers) ->
    [Client ! {updt,Msg} || Client <- Receivers].


%% Realiza la jugada argumento en Table y devuelve el nuevo estado
%% del tablero, si la jugada no es "LEAVE", y si es valida
ttt_play(Table,[Play],T) ->
    try
        %% Asegurarse que la jugada sea un numero
        N = list_to_integer(Play),
        %% Verificar que los numeros son correctos, y que el lugar no
        %% fue jugado antes
        0 = lists:nth(N,Table),
        %% Se devuelve el tablero con el N-esimo numero T
        lists:sublist(Table,N-1) ++ [T] ++ lists:nthtail(N,Table)
    catch
        E:R -> if
                Play =:= "LEAVE" -> leave;
                true -> badargs
               end
    end.


%% Chequea si la ultima jugada formo una linea de 3
%% Si lo hizo devuelve win y la linea ganadora, si no ok
ttt_test_table([A1,A2,A3,B1,B2,B3,C1,C2,C3],T) ->
    if
        A1 =:= T and A2 =:= T and A3 =:= T -> {win,[1,2,3]};
        B1 =:= T and B2 =:= T and B3 =:= T -> {win,[4,5,6]};
        C1 =:= T and C2 =:= T and C3 =:= T -> {win,[7,8,9]};
        A1 =:= T and B1 =:= T and C1 =:= T -> {win,[1,3,7]};
        A2 =:= T and B2 =:= T and C2 =:= T -> {win,[2,5,8]};
        A3 =:= T and B3 =:= T and C3 =:= T -> {win,[3,6,9]};
        A1 =:= T and B2 =:= T and C3 =:= T -> {win,[1,5,9]};
        A3 =:= T and B2 =:= T and C1 =:= T -> {win,[3,5,7]};
        true -> ok
    end.


%% El juego en si
ttt_phase3(IdProcs,Names,Table,Turn,Wtcs,GID,Count) ->
    OtherPlayer = (Turn rem 2) + 1,
    %% Recibir pedidos de (des)observacion
    Info = string:join([Names, " "),
    {InWtcs,OutWtcs} = watch_list([],[],Info,GID),
    NewWtcs = InWtcs ++ (Wtcs -- OutWtcs),
    %% Mandar updt a todos
    TableStr = lists:append([integer_to_list(X) || X <- Table]),
    Info1 = TableStr ++ " " ++ integer_to_list(Turn),
    updt_bcast(string:join([GID,TableStr,integer_to_list(Turn)], " "),
                lists:nth(Turn,IdProcs) ++ NewWtcs),
    %% Recibir y realizar jugada
    receive
        {play,Ret,Play,lists:nth(Turn,IdProcs)} ->
            case ttt_play(Table,Play,Turn) of
                leave ->
                    %% El jugador se retira, se termina el juego
                    Ret ! {ok, GID ++ " LEFT"},
                    Recs = [lists:nth(OtherPlayer,IdProcs) | NewWtcs],
                    ttt_end(lists:nth(OtherPlayer,Names),Recs,GID,leave);
                badargs ->
                    %% Jugada invalida, se pierde el turno
                    Ret ! {ok, GID ++ " INVALID"}
                    ttt_phase3(IdProcs,Names,Table,OtherPlayer,NewWtcs,GID);
                NewTable ->
                    Ret ! {ok, GID},
                    %% Comprobar tabla
                    case ttt_test_table(NewTable) of
                        ok ->
                            %% Si no hay mas casillas para rellenar, hay empate
                            case Count of
                                9 -> ttt_end(false,IdProcs++NewWtcs,GID,draw);
                                _ -> ttt_phase3(IdProcs,Names,NewTable,OtherPlayer,NewWtcs,GID,Count+1);
                        {win,Hit} -> ttt_end(Turn,IdProcs++NewWtcs,GID,Hit)
                    end
            end
    %% El jugador tiene 10 segundos para realizar la jugada
    after 10000 ->
        ttt_end(lists:nth(OtherPlayer,Names), IdProcs++NewWtcs, GID, timeout)
    end.


%% Terminacion del juego
%% Se manda un ultimo update a los jugadores y observadores informando
%% quien gano y por que
ttt_end(WinnerN, Players, Wtcs, GID, Reason) ->
    games ! {del,GID},
    [Player ! {del,play,GID} || Player <- Players],
    [Watcher ! {del,watch,GID} || Watcher <- Wtcs],
    InfRecs = Players ++ Wtcs,
    case Reason of
        draw ->
            updt_bcast(GID ++ " END DRAW", InfRecs);
        leave ->
            updt_bcast(GID ++ " END " ++  WinnerN ++ " GAMELEFT", InfRecs);
        timeout ->
            updt_bcast(GID ++ " END " ++  WinnerN ++ " TIMEOUT", InfRecs);
        Hit ->
            HitS = lists:append([integer_to_list(X) || X <- Hit])
            updt_bcast(GID ++ " END " ++  WinnerN ++ " " ++ HitS, InfRecs)
    end.



