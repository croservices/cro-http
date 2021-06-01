use Cro::HTTP::Router;

sub resourcey-routes() is export {
    route {
        resources-from %?RESOURCES;

        get -> 'index.html' {
            resource 'index.html';
        }
        get -> 'test.1' {
            resource 'folder/test.txt';
        }
        get -> 'test.2' {
            resource 'folder', 'test.txt';
        }
        get -> 'folder-indexes' {
            resource 'folder', :indexes(['test.txt']);
        }
        get -> 'root-indexes1' {
            resource '', :indexes(['index.html']);
        }
        get -> 'root-indexes2' {
            resource :indexes(['index.html']);
        }
    }
}
