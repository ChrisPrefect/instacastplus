#!/bin/sh
# Type a script or drag a script file from your workspace to insert its path.
# VERSION_FILE="${TARGET_BUILD_DIR}/${EXECUTABLE_NAME}.app/svnversion"
# rm -f "${VERSION_FILE}"
# rm -f "${VERSION_FILE}.svn"
# echo $BUILDNUMBER >> "${VERSION_FILE}.svn"
# sed "s/[[:alpha:]]//g" "${VERSION_FILE}.svn" > "${VERSION_FILE}"
# rm -f "${VERSION_FILE}.svn"

# BUILDNUMBER=`cat "${VERSION_FILE}"`


# INFOPLIST_FULL_PATH="${TARGET_BUILD_DIR}/${EXECUTABLE_NAME}.app/Info.plist"
# plutil -convert xml1 "${INFOPLIST_FULL_PATH}"

# sed "s/<string>v[[:digit:]][[:digit:]]*[[:alpha:]]*/<string>${BUILDNUMBER}/" < "${INFOPLIST_FULL_PATH}" > "${INFOPLIST_FULL_PATH}.versioned"
# mv "${INFOPLIST_FULL_PATH}.versioned" "${INFOPLIST_FULL_PATH}"

# plutil -convert binary1 "${INFOPLIST_FULL_PATH}" 

