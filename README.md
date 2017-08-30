# vmclone-linux-parallel
Wrapper and modification for the vmclone-lin.pl script to allow full deployments

# Usage
clone.pl -c <path to ini file> -u DOMAIN\\USERNAME -p PASSWORD*

*Note that any special characters, such as a "!" should be escaped by a backslash (\) when used from the Linux command line

# Files:
* clone.pl: main program
* demo.ini: Sample config file
* post_clone.pl: Post-clone configuations script
* test-clones.pl: Script to ensure built clones are available and configured as desired

# Directories
* xml/: Contains the XML template and also the resulting clone specifications
* logs/: Where log files are written for each clone operation
