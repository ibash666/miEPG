#!/bin/bash

# ==============================================================================
# Script: miEPG.sh
# Version: 3.8
#
# Funcion:
#   - Descarga una o varias fuentes XMLTV.
#   - Genera listados de canales.
#   - Selecciona y renombra canales mediante canales.txt.
#   - Mantiene o sustituye logos.
#   - Ajusta horarios por canal.
#   - Limita dias pasados y futuros.
#   - Recupera historico solo de canales que siguen seleccionados.
#   - Elimina programas residuales y referencias huerfanas.
#   - Valida el XML final.
# ==============================================================================


# ==============================================================================
# CONFIGURACION Y LIMPIEZA INICIAL
# ==============================================================================

if [ ! -f epgs.txt ]; then
    echo "ERROR: No existe epgs.txt"
    exit 1
fi

if [ ! -f canales.txt ]; then
    echo "ERROR: No existe canales.txt"
    exit 1
fi

# Eliminar lineas vacias.
sed -i '/^[[:space:]]*$/d' epgs.txt
sed -i '/^[[:space:]]*$/d' canales.txt

# Eliminar temporales de una ejecucion anterior.
rm -f EPG_temp* canales_epg*.txt

# Crear los archivos temporales necesarios.
: > EPG_temp.xml
: > EPG_temp1.xml
: > EPG_temp2.xml

epg_count=0


# ==============================================================================
# DESCARGA DE FUENTES EPG
# ==============================================================================

echo "─── DESCARGANDO EPGs ───"

while IFS=, read -r epg; do

    # Limpiar espacios y retornos de carro.
    epg="$(printf '%s' "$epg" | tr -d '\r' | xargs)"

    if [ -z "$epg" ]; then
        continue
    fi

    ((epg_count++))

    extension="${epg##*.}"

    rm -f EPG_temp00.xml EPG_temp00.xml.gz

    if [ "$extension" = "gz" ]; then

        echo " │ Descargando y descomprimiendo: $epg"

        wget \
            --timeout=60 \
            --tries=3 \
            --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36" \
            -O EPG_temp00.xml.gz \
            -q \
            "$epg"

        if [ ! -s EPG_temp00.xml.gz ]; then
            echo " └─► ERROR: El archivo descargado esta vacio o no se descargo"
            rm -f EPG_temp00.xml.gz
            continue
        fi

        if ! gzip -t EPG_temp00.xml.gz 2>/dev/null; then
            echo " └─► ERROR: El archivo no es un gzip valido"
            rm -f EPG_temp00.xml.gz
            continue
        fi

        gzip -d -f EPG_temp00.xml.gz

    else

        echo " │ Descargando: $epg"

        wget \
            --timeout=60 \
            --tries=3 \
            --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140 Safari/537.36" \
            -O EPG_temp00.xml \
            -q \
            "$epg"

        if [ ! -s EPG_temp00.xml ]; then
            echo " └─► ERROR: El archivo descargado esta vacio o no se descargo"
            rm -f EPG_temp00.xml
            continue
        fi

    fi

    if [ -f EPG_temp00.xml ]; then

        listado="canales_epg${epg_count}.txt"

        echo " └─► Generando listado de canales: $listado"
        echo "# Fuente: $epg" > "$listado"

        awk '
        /<channel / {
            match($0, /id="([^"]+)"/, a)
            id = a[1]
            name = ""
            logo = ""
        }

        /<display-name[^>]*>/ && name == "" {
            match(
                $0,
                /<display-name[^>]*>([^<]+)<\/display-name>/,
                a
            )
            name = a[1]
        }

        /([^"/, a)
            logo = a[1]
        }

        /<\/channel>/ {
            print id "," name "," logo
        }
        ' EPG_temp00.xml >> "$listado"

        # Normalizar XML para que cada etiqueta principal quede en su linea.
        sed 's/></>\n</g' EPG_temp00.xml >> EPG_temp.xml

    fi

done < epgs.txt


if [ ! -s EPG_temp.xml ]; then
    echo "ERROR: No se ha podido obtener ninguna fuente EPG valida"
    exit 1
fi


# ==============================================================================
# NORMALIZACION DE canales.txt
# ==============================================================================

echo "─── PROCESANDO CANALES ───"

mapfile -t canales < canales.txt

for i in "${!canales[@]}"; do

    IFS=',' read -r old new logo offset <<< "${canales[$i]}"

    old="$(printf '%s' "${old:-}" | xargs)"
    new="$(printf '%s' "${new:-}" | xargs)"
    logo="$(printf '%s' "${logo:-}" | xargs)"
    offset="$(printf '%s' "${offset:-}" | xargs)"

    # Compatibilidad con formatos que ponen el offset en la tercera columna.
    if [[ "$logo" =~ ^[+-]?[0-9]+$ ]] && [ -z "$offset" ]; then
        offset="$logo"
        logo=""
    fi

    if [ -z "$old" ]; then
        echo " │ Saltando linea sin nombre de origen"
        canales[$i]=""
        continue
    fi

    if [ -z "$new" ]; then
        new="$old"
    fi

    canales[$i]="$old,$new,$logo,$offset"

done


# ==============================================================================
# PROCESAMIENTO DE LOS CANALES SELECCIONADOS
# ==============================================================================

for linea in "${canales[@]}"; do

    if [ -z "$linea" ]; then
        continue
    fi

    IFS=',' read -r old new logo offset <<< "$linea"

    export OLD_CHANNEL="$old"
    export NEW_CHANNEL="$new"
    export NEW_LOGO="$logo"
    export CHANNEL_OFFSET="$offset"

    # Extraer el canal y sus programas con un parser XML real.
    python3 <<'PY'
import copy
import os
import sys
import xml.etree.ElementTree as ET

source_file = "EPG_temp.xml"
channel_output = "EPG_temp01.xml"
programme_output = "EPG_temp02.xml"

old_name = os.environ.get("OLD_CHANNEL", "").strip()
new_name = os.environ.get("NEW_CHANNEL", "").strip()
new_logo = os.environ.get("NEW_LOGO", "").strip()

if not old_name:
    sys.exit(2)

try:
    tree = ET.parse(source_file)
    root = tree.getroot()
except Exception as exc:
    print(
        f"ERROR al analizar {source_file}: {exc}",
        file=sys.stderr
    )
    sys.exit(1)

source_channel = None

for channel in root.findall("channel"):
    if channel.get("id") == old_name:
        source_channel = channel
        break

programmes = [
    programme
    for programme in root.findall("programme")
    if programme.get("channel") == old_name
]

if source_channel is None and not programmes:
    # Crear archivos vacios para indicar que no hay coincidencias.
    open(channel_output, "w", encoding="utf-8").close()
    open(programme_output, "w", encoding="utf-8").close()
    sys.exit(3)

# Construir el nuevo canal.
new_channel = ET.Element("channel", {"id": new_name})

suffixes = []

if os.path.exists("variables.txt"):
    with open("variables.txt", "r", encoding="utf-8") as variables:
        for line in variables:
            if line.strip().startswith("display-name="):
                value = line.split("=", 1)[1].strip()
                suffixes = [
                    item.strip()
                    for item in value.split(",")
                    if item.strip()
                ]
                break

if suffixes:
    for suffix in suffixes:
        display_name = ET.SubElement(new_channel, "display-name")
        display_name.text = f"{new_name} {suffix}"
else:
    display_name = ET.SubElement(new_channel, "display-name")
    display_name.text = new_name

if new_logo:
    ET.SubElement(new_channel, "icon", {"src": new_logo})
elif source_channel is not None:
    original_icon = source_channel.find("icon")

    if original_icon is not None and original_icon.get("src"):
        ET.SubElement(
            new_channel,
            "icon",
            {"src": original_icon.get("src")}
        )

ET.indent(new_channel, space="  ")

with open(channel_output, "w", encoding="utf-8") as output:
    output.write(
        ET.tostring(
            new_channel,
            encoding="unicode",
            short_empty_elements=True
        )
    )
    output.write("\n")

with open(programme_output, "w", encoding="utf-8") as output:
    for programme in programmes:
        updated = copy.deepcopy(programme)
        updated.set("channel", new_name)

        ET.indent(updated, space="  ")

        output.write(
            ET.tostring(
                updated,
                encoding="unicode",
                short_empty_elements=True
            )
        )
        output.write("\n")

print(len(programmes))
PY

    estado_python=$?

    if [ "$estado_python" -eq 3 ]; then
        echo " │ Saltando canal: $old ··· 0 coincidencias"
        rm -f EPG_temp01.xml EPG_temp02.xml
        continue
    fi

    if [ "$estado_python" -ne 0 ]; then
        echo " │ ERROR procesando el canal: $old"
        rm -f EPG_temp01.xml EPG_temp02.xml
        continue
    fi

    contar_channel="$(grep -c '<programme ' EPG_temp02.xml 2>/dev/null || true)"
    contar_channel="${contar_channel:-0}"

    if [ "$contar_channel" -gt 0 ]; then

        if [ -n "$logo" ]; then
            echo " │ Nombre EPG: $old · Nuevo nombre: $new · Cambiando logo ··· $contar_channel programas"
        else
            echo " │ Nombre EPG: $old · Nuevo nombre: $new · Manteniendo logo ··· $contar_channel programas"
        fi

        # Anadir la definicion del canal evitando IDs duplicados.
        export CHANNEL_FRAGMENT_FILE="EPG_temp01.xml"

        python3 <<'PY'
import os
import xml.etree.ElementTree as ET

destination = "EPG_temp1.xml"
fragment_file = os.environ["CHANNEL_FRAGMENT_FILE"]

with open(fragment_file, "r", encoding="utf-8") as source:
    fragment = source.read().strip()

if not fragment:
    raise SystemExit(0)

new_channel = ET.fromstring(fragment)
new_id = new_channel.get("id")

existing_ids = set()

if os.path.exists(destination):
    with open(destination, "r", encoding="utf-8") as source:
        existing_fragment = source.read()

    if existing_fragment.strip():
        root = ET.fromstring(
            "<root>\n" + existing_fragment + "\n</root>"
        )

        existing_ids = {
            channel.get("id")
            for channel in root.findall("channel")
            if channel.get("id")
        }

if new_id not in existing_ids:
    with open(destination, "a", encoding="utf-8") as output:
        output.write(fragment)
        output.write("\n")
PY

        # Ajustar horario cuando existe un offset numerico.
        if [[ "$offset" =~ ^[+-]?[0-9]+$ ]]; then

            echo " └─► Ajustando hora en el canal $new ($offset horas)"

            export OFFSET="$offset"
            export NEW_CHANNEL="$new"

            perl -MDate::Parse -MDate::Format -i'' -pe '
            BEGIN {
                $offset_sec = $ENV{OFFSET} * 3600;
                $new_channel_name = $ENV{NEW_CHANNEL};
            }

            if (
                /<programme start="([^"]+) ([+-]?\d+)" stop="([^"]+) ([+-]?\d+)" channel="[^"]+">/
            ) {
                my (
                    $start_time_str,
                    $start_tz,
                    $stop_time_str,
                    $stop_tz
                ) = ($1, $2, $3, $4);

                my $start_fmt =
                    substr($start_time_str, 0, 4) . "-" .
                    substr($start_time_str, 4, 2) . "-" .
                    substr($start_time_str, 6, 2) . " " .
                    substr($start_time_str, 8, 2) . ":" .
                    substr($start_time_str, 10, 2) . ":" .
                    substr($start_time_str, 12, 2);

                my $stop_fmt =
                    substr($stop_time_str, 0, 4) . "-" .
                    substr($stop_time_str, 4, 2) . "-" .
                    substr($stop_time_str, 6, 2) . " " .
                    substr($stop_time_str, 8, 2) . ":" .
                    substr($stop_time_str, 10, 2) . ":" .
                    substr($stop_time_str, 12, 2);

                my $start =
                    str2time("$start_fmt $start_tz") +
                    $offset_sec;

                my $stop =
                    str2time("$stop_fmt $stop_tz") +
                    $offset_sec;

                my $start_formatted =
                    time2str(
                        "%Y%m%d%H%M%S $start_tz",
                        $start
                    );

                my $stop_formatted =
                    time2str(
                        "%Y%m%d%H%M%S $stop_tz",
                        $stop
                    );

                s{
                    <programme
                    \s+
                    start="[^"]+"
                    \s+
                    stop="[^"]+"
                    \s+
                    channel="[^"]+"
                    >
                }{
                    <programme start="$start_formatted" stop="$stop_formatted" channel="$new_channel_name">
                }x;
            }
            ' EPG_temp02.xml

        fi

        cat EPG_temp02.xml >> EPG_temp2.xml

    else
        echo " │ Saltando canal: $old ··· 0 programas"
    fi

    rm -f EPG_temp01.xml EPG_temp02.xml

done


# ==============================================================================
# PROCESAMIENTO DE LIMITES TEMPORALES Y ACUMULACION
# ==============================================================================

echo "─── PROCESANDO LIMITES TEMPORALES Y ACUMULACIÓN ───"

# Garantizar que los archivos temporales existen.
touch EPG_temp1.xml
touch EPG_temp2.xml


# ==============================================================================
# RECUPERAR HISTORICO SOLO DE CANALES SELECCIONADOS
# ==============================================================================

if [ -s epg_acumulado.xml ] && [ -s EPG_temp1.xml ]; then

    echo " Rescatando programas válidos de epg_acumulado.xml..."

    python3 <<'PY'
import copy
import os
import xml.etree.ElementTree as ET

channels_file = "EPG_temp1.xml"
accumulated_file = "epg_acumulado.xml"
output_file = "EPG_temp2.xml"

with open(channels_file, "r", encoding="utf-8") as source:
    channel_fragment = source.read()

try:
    channel_root = ET.fromstring(
        "<root>\n" + channel_fragment + "\n</root>"
    )
except Exception as exc:
    raise SystemExit(
        f"ERROR analizando los canales actuales: {exc}"
    )

valid_channels = {
    channel.get("id")
    for channel in channel_root.findall("channel")
    if channel.get("id")
}

try:
    accumulated_tree = ET.parse(accumulated_file)
    accumulated_root = accumulated_tree.getroot()
except Exception as exc:
    raise SystemExit(
        f"ERROR analizando epg_acumulado.xml: {exc}"
    )

recovered = 0
discarded = 0
discarded_by_channel = {}

with open(output_file, "a", encoding="utf-8") as output:

    for programme in accumulated_root.findall("programme"):

        channel_id = programme.get("channel")

        if channel_id in valid_channels:

            item = copy.deepcopy(programme)
            ET.indent(item, space="  ")

            output.write(
                ET.tostring(
                    item,
                    encoding="unicode",
                    short_empty_elements=True
                )
            )
            output.write("\n")

            recovered += 1

        else:

            discarded += 1
            channel_name = channel_id or "(sin channel)"

            discarded_by_channel[channel_name] = (
                discarded_by_channel.get(channel_name, 0) + 1
            )

print(f" ─► Canales válidos actuales: {len(valid_channels)}")
print(f" ─► Programas históricos recuperados: {recovered}")
print(f" ─► Programas históricos descartados: {discarded}")

if discarded_by_channel:
    print(" ─► Históricos descartados por canal:")

    for channel_name, amount in sorted(
        discarded_by_channel.items()
    ):
        print(f"    - {channel_name}: {amount}")
PY

    if [ $? -ne 0 ]; then
        echo " ADVERTENCIA: No se pudo recuperar el histórico acumulado"
    fi

else

    if [ ! -s epg_acumulado.xml ]; then
        echo " No existe un histórico acumulado válido."
    fi

fi


# ==============================================================================
# LEER LIMITES TEMPORALES
# ==============================================================================

dias_pasados=0
dias_futuros=99

if [ -f variables.txt ]; then

    valor_dias_pasados="$(
        grep -m1 '^dias-pasados=' variables.txt |
        cut -d'=' -f2- |
        xargs
    )"

    valor_dias_futuros="$(
        grep -m1 '^dias-futuros=' variables.txt |
        cut -d'=' -f2- |
        xargs
    )"

    if [[ "$valor_dias_pasados" =~ ^[0-9]+$ ]]; then
        dias_pasados="$valor_dias_pasados"
    fi

    if [[ "$valor_dias_futuros" =~ ^[0-9]+$ ]]; then
        dias_futuros="$valor_dias_futuros"
    fi

fi

fecha_corte_pasado="$(
    date -d "$dias_pasados days ago 00:00" +"%Y%m%d%H%M%S"
)"

fecha_corte_futuro="$(
    date -d "$dias_futuros days 02:00" +"%Y%m%d%H%M%S"
)"

echo " Limpieza Pasado: Manteniendo desde $fecha_corte_pasado ($dias_pasados días)"
echo " Limpieza Futuro: Limitando hasta $fecha_corte_futuro ($dias_futuros días)"


# ==============================================================================
# FILTRO TEMPORAL Y DEDUPLICACION
# ==============================================================================

export FECHA_CORTE_PASADO="$fecha_corte_pasado"
export FECHA_CORTE_FUTURO="$fecha_corte_futuro"

perl -i -ne '
    BEGIN {
        $c_old = $ENV{FECHA_CORTE_PASADO};
        $c_new = $ENV{FECHA_CORTE_FUTURO};

        %visto = ();

        $pasados = 0;
        $futuros = 0;
        $duplicados = 0;
        $aceptados = 0;

        $imprimir = 0;
    }

    if (
        /<programme start="(\d{14})[^"]*" stop="[^"]+" channel="([^"]+)">/
    ) {
        $inicio = $1;
        $canal = $2;

        # Se incluye el inicio, el canal y la etiqueta completa.
        # Esto evita eliminar programas distintos que puedan comenzar
        # a la misma hora en el mismo canal.
        $llave = "$inicio-$canal-$_";

        if ($inicio < $c_old) {
            $pasados++;
            $imprimir = 0;
        }
        elsif ($inicio > $c_new) {
            $futuros++;
            $imprimir = 0;
        }
        elsif ($visto{$llave}++) {
            $duplicados++;
            $imprimir = 0;
        }
        else {
            $aceptados++;
            $imprimir = 1;
        }
    }

    print if $imprimir;

    if (/<\/programme>/) {
        $imprimir = 0;
    }

    END {
        print STDERR " ─► Añadidos/Mantenidos: $aceptados\n";
        print STDERR " ─► Pasados eliminados: $pasados\n";
        print STDERR " ─► Futuros eliminados: $futuros\n";
        print STDERR " ─► Duplicados eliminados: $duplicados\n";
    }
' EPG_temp2.xml


# ==============================================================================
# CREAR XML FINAL
# ==============================================================================

date_stamp="$(date +"%d/%m/%Y %R")"

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<tv generator-info-name="miEPG v3.8" generator-info-url="https://github.com/davidmuma/miEPG">'

    # Canales seleccionados.
    if [ -s EPG_temp1.xml ]; then
        cat EPG_temp1.xml
    fi

    # Programas nuevos e historicos.
    if [ -s EPG_temp2.xml ]; then
        cat EPG_temp2.xml
    fi

    echo '</tv>'

} > miEPG.xml


# ==============================================================================
# LIMPIEZA FINAL DE PROGRAMAS HUERFANOS
# ==============================================================================

echo "─── LIMPIEZA FINAL DE PROGRAMAS HUÉRFANOS ───"

python3 <<'PY'
import os
import xml.etree.ElementTree as ET

file_name = "miEPG.xml"

if not os.path.exists(file_name):
    raise SystemExit(f"ERROR: No existe {file_name}")

try:
    tree = ET.parse(file_name)
    root = tree.getroot()
except Exception as exc:
    raise SystemExit(
        f"ERROR: No se puede analizar miEPG.xml: {exc}"
    )

valid_channels = {
    channel.get("id")
    for channel in root.findall("channel")
    if channel.get("id")
}

programmes = list(root.findall("programme"))

removed = 0
removed_by_channel = {}

for programme in programmes:

    channel_id = programme.get("channel")

    if channel_id not in valid_channels:

        root.remove(programme)
        removed += 1

        channel_name = channel_id or "(sin channel)"

        removed_by_channel[channel_name] = (
            removed_by_channel.get(channel_name, 0) + 1
        )

ET.indent(tree, space="  ")

tree.write(
    file_name,
    encoding="UTF-8",
    xml_declaration=True,
    short_empty_elements=True
)

print(f" │ Canales válidos: {len(valid_channels)}")
print(f" │ Programas revisados: {len(programmes)}")
print(f" │ Programas conservados: {len(programmes) - removed}")
print(f" └─► Programas huérfanos eliminados: {removed}")

if removed_by_channel:

    print(" Canales residuales encontrados:")

    for channel_name, amount in sorted(
        removed_by_channel.items()
    ):
        print(f"   - {channel_name}: {amount}")
PY

if [ $? -ne 0 ]; then
    echo "ERROR: Ha fallado la limpieza final de programas huérfanos"
    exit 1
fi


# ==============================================================================
# VALIDACION LOGICA XMLTV
# ==============================================================================

echo "─── VALIDACIÓN DE REFERENCIAS XMLTV ───"

python3 <<'PY'
import xml.etree.ElementTree as ET

tree = ET.parse("miEPG.xml")
root = tree.getroot()

channel_ids = [
    channel.get("id")
    for channel in root.findall("channel")
    if channel.get("id")
]

channel_set = set(channel_ids)

programme_channels = [
    programme.get("channel")
    for programme in root.findall("programme")
]

orphan_channels = sorted({
    channel_id
    for channel_id in programme_channels
    if channel_id not in channel_set
})

channels_without_programmes = sorted(
    channel_set - set(programme_channels)
)

duplicate_channel_ids = sorted({
    channel_id
    for channel_id in channel_ids
    if channel_ids.count(channel_id) > 1
})

if orphan_channels:
    print(" ERROR: Hay programas huérfanos:")
    for channel_id in orphan_channels:
        print(f"   - {channel_id}")
    raise SystemExit(1)

if duplicate_channel_ids:
    print(" ERROR: Hay IDs de canal duplicados:")
    for channel_id in duplicate_channel_ids:
        print(f"   - {channel_id}")
    raise SystemExit(1)

print(" │ No existen programas huérfanos.")
print(" │ No existen IDs de canal duplicados.")

if channels_without_programmes:
    print(" │ Canales definidos sin programación:")
    for channel_id in channels_without_programmes:
        print(f"   - {channel_id}")
else:
    print(" └─► Todos los canales definidos tienen programación.")
PY

if [ $? -ne 0 ]; then
    echo "ERROR: La validación lógica XMLTV ha fallado"
    exit 1
fi


# ==============================================================================
# VALIDACION FINAL DEL XML
# ==============================================================================

echo "─── VALIDACIÓN FINAL DEL XML ───"

error_log="$(xmllint --noout miEPG.xml 2>&1)"
estado_xmllint=$?

if [ "$estado_xmllint" -eq 0 ]; then

    echo " │ El archivo XML está perfectamente formado."

    num_canales="$(grep -c '<channel ' miEPG.xml || true)"
    num_programas="$(grep -c '<programme ' miEPG.xml || true)"
    tamano_bytes="$(wc -c < miEPG.xml | xargs)"

    echo " │ Canales: $num_canales"
    echo " │ Programas: $num_programas"
    echo " │ Tamaño: $tamano_bytes bytes"
    echo " └─► Fecha de generación: $date_stamp"

    # Solo actualizar el acumulado cuando todo el XML sea válido.
    cp miEPG.xml epg_acumulado.xml

    echo " epg_acumulado.xml actualizado para la próxima sesión."

else

    echo " ERROR: Se han detectado fallos en la estructura del XML."
    echo "──────────────────────────────────────────────────────────────────"

    lineas_con_error="$(
        printf '%s\n' "$error_log" |
        grep -oP '(?<=miEPG.xml:)\d+' |
        sort -nu
    )"

    if [ -n "$lineas_con_error" ]; then

        echo "Resumen de líneas con errores:"

        for linea in $lineas_con_error; do

            detalle="$(
                printf '%s\n' "$error_log" |
                grep "miEPG.xml:$linea:" |
                head -1 |
                cut -d':' -f3-
            )"

            contenido_linea="$(
                sed -n "${linea}p" miEPG.xml |
                xargs
            )"

            echo " Línea $linea:"
            echo "   Error: $detalle"
            echo "   Texto: \"$contenido_linea\""
            echo "───"

        done

    else

        printf '%s\n' "$error_log"

    fi

    echo "──────────────────────────────────────────────────────────────────"
    echo " ADVERTENCIA: epg_acumulado.xml NO se ha actualizado."

    rm -f EPG_temp* 2>/dev/null

    exit 1

fi


# ==============================================================================
# LIMPIEZA FINAL
# ==============================================================================

rm -f EPG_temp* 2>/dev/null

echo "─── PROCESO FINALIZADO ───"
