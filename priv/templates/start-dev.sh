#!/bin/sh
cd `dirname $0`
exec erl -pa $PWD/ebin $PWD/apps/*/ebin -boot start_sasl -s reloader -s {{appid}}
