#!/usr/bin/env bash

module_file="FHEM/60_uba.pm"
commandref_de_source="CommandRef.de.md"
commandref_en_source="CommandRef.en.md"
meta_source="meta.json"
name="uba"
controls_file="controls_uba.txt"
changed_file="CHANGED"

#   +------------------------------------------------------------
#
#       Substitute the place holders in the module file with
#       the converted markdown documentation
#
#   +------------------------------------------------------------
substitute() {
    #echo "" >> .${commandref_de_source}.html
    #pandoc -fmarkdown_github -t html ${commandref_de_source} | \
    #    tidy -qi -w --show-body-only yes - >> .${commandref_de_source}.html
    #echo "" >> .${commandref_de_source}.html
    #sed -i -ne "/^=begin html_DE$/ {p; r .${commandref_de_source}.html" -e ":a; n; /^=end html_DE$/ {p; b}; ba}; p" ${module_file}

    #echo "" >> .${commandref_en_source}.html
    #pandoc -fmarkdown_github -t html ${commandref_en_source} | \
    #    tidy -qi -w --show-body-only yes - >> .${commandref_en_source}.html
    #echo "" >> .${commandref_en_source}.html
    #sed -i -ne "/^=begin html$/ {p; r .${commandref_en_source}.html" -e ":a; n; /^=end html$/ {p; b}; ba}; p" ${module_file}

    #sed -i -ne "/^=for :application\/json;q=META.json 59_Twilight.pm$/ {p; r ${meta_source}" -e ":a; n; /^=end :application\/json;q=META.json$/ {p; b}; ba}; p" ${module_file}

    # clean up
    #rm -rf .CommandRef.*

    # add created files
    git add FHEM/*.pm
    #git add CommandRef.*
    #git add meta.json
}

#add_hooks() {
#    rm -rf build/hooks/*
#    cp -R .git/hooks/* build/hooks/
#    git add build/hooks/
#}

create_controlfile() {
    rm ${controls_file}
    find -type f \( -path './FHEM/*' -o -path './www/*' \) -print0 | while IFS= read -r -d '' f;
    do
        echo "DEL ${f}" >> ${controls_file}
        out="UPD "$(stat -c %y  $f | cut -d. -f1 | awk '{printf "%s_%s",$1,$2}')" "$(stat -c %s $f)" ${f}"
        echo ${out//.\//} >> ${controls_file}
    done
    git add ${controls_file}
}

update_changed() {
    rm ${changed_file}
    echo "Last $name updates ($(date +%d.%m.%Y))" > "${changed_file}"
    echo "" >> ${changed_file}
    git log -5 HEAD --pretty="  %h %ad %s" --date=format:"%d.%m.%Y %H:%M" FHEM/  >> ${changed_file}
    git add CHANGED
}

substitute
#add_hooks
# only create new controls file if FHEM/* is changed
test "$(git diff --cached --name-only --diff-filter=ACM | grep -c 'FHEM/')" -gt 0 && create_controlfile
update_changed
